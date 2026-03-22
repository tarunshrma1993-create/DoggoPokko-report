#!/usr/bin/env python3
"""
Instagram engagement calculator + HTML report generator.

Data sources:
  1) CSV or JSON with per-post metrics (from Insights export or manual entry).
  2) Meta Graph API: put INSTAGRAM_ACCESS_TOKEN and INSTAGRAM_USER_ID in a local ".env"
     file (gitignored), or export them in the shell — then run with --api.

Required Meta app permissions for full data:
  - instagram_basic — user profile + media
  - instagram_manage_insights — per-media reach / engagement / saved insights

Token: long-lived User access token from a System User or Graph API Explorer (dev only).
See: https://developers.facebook.com/docs/instagram-platform

Instagram does not publish engagement on public profile pages; you need Insights
or the Graph API with a Business/Creator account linked to a Facebook Page.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def load_env_file(path: Path) -> None:
    """Load KEY=value pairs from a file into os.environ (does not override existing vars)."""
    if not path.is_file():
        return
    text = path.read_text(encoding="utf-8-sig")
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].strip()
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        if not key:
            continue
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        if key not in os.environ:
            os.environ[key] = val


def _env_file_path() -> Path:
    override = os.environ.get("DOTENV_FILE", "").strip()
    if override:
        return Path(override).expanduser()
    return Path(__file__).resolve().parent / ".env"


@dataclass
class PostMetrics:
    post_id: str
    likes: int = 0
    comments: int = 0
    saves: int = 0
    shares: int = 0
    reach: int | None = None
    impressions: int | None = None
    """From Graph API insight `impressions` when available (legacy / some media types)."""
    engagement_total: int | None = None
    """From Graph API insight `engagement` or `total_interactions` when available."""


@dataclass
class ProfileSnapshot:
    username: str
    display_name: str = ""
    followers: int = 0
    period_label: str = ""
    posts: list[PostMetrics] = field(default_factory=list)
    source_note: str = ""


def _int_cell(row: dict[str, str], key: str, default: int = 0) -> int:
    v = row.get(key, "").strip()
    if v == "":
        return default
    try:
        return int(float(v))
    except ValueError:
        return default


def load_csv(path: Path) -> list[PostMetrics]:
    posts: list[PostMetrics] = []
    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            pid = (row.get("post_id") or row.get("id") or "").strip() or str(len(posts) + 1)
            reach_raw = row.get("reach", "").strip()
            reach = _int_cell(row, "reach", 0) if reach_raw else None
            if reach == 0:
                reach = None
            posts.append(
                PostMetrics(
                    post_id=pid,
                    likes=_int_cell(row, "likes", 0),
                    comments=_int_cell(row, "comments", 0),
                    saves=_int_cell(row, "saves", 0),
                    shares=_int_cell(row, "shares", 0),
                    reach=reach,
                )
            )
    return posts


def load_json_config(path: Path) -> ProfileSnapshot:
    data = json.loads(path.read_text(encoding="utf-8"))
    prof = data.get("profile", {})
    posts_raw = data.get("posts", [])
    posts: list[PostMetrics] = []
    for i, p in enumerate(posts_raw):
        posts.append(
            PostMetrics(
                post_id=str(p.get("post_id", i + 1)),
                likes=int(p.get("likes", 0)),
                comments=int(p.get("comments", 0)),
                saves=int(p.get("saves", 0)),
                shares=int(p.get("shares", 0)),
                reach=int(p["reach"]) if p.get("reach") is not None else None,
            )
        )
    return ProfileSnapshot(
        username=str(prof.get("username", "unknown")),
        display_name=str(prof.get("display_name", "")),
        followers=int(prof.get("followers", 0)),
        period_label=str(prof.get("period_label", "")),
        posts=posts,
        source_note="JSON config",
    )


def aggregate_engagement(p: PostMetrics) -> int:
    if p.engagement_total is not None:
        return p.engagement_total
    return p.likes + p.comments + p.saves + p.shares


def compute_rates(profile: ProfileSnapshot) -> dict[str, Any]:
    posts = profile.posts
    n = len(posts)
    if n == 0:
        return {
            "post_count": 0,
            "avg_engagement_per_post": 0.0,
            "rate_by_followers_pct": None,
            "rate_by_reach_pct": None,
            "total_engagements": 0,
            "avg_reach": None,
        }

    total_eng = sum(aggregate_engagement(p) for p in posts)
    avg_eng = total_eng / n

    rate_followers = None
    if profile.followers > 0:
        rate_followers = (avg_eng / profile.followers) * 100.0

    reaches = [p.reach for p in posts if p.reach is not None and p.reach > 0]
    rate_reach = None
    avg_reach = None
    if reaches:
        avg_reach = sum(reaches) / len(reaches)
        total_reach = sum(reaches)
        if total_reach > 0:
            rate_reach = (total_eng / total_reach) * 100.0

    return {
        "post_count": n,
        "avg_engagement_per_post": round(avg_eng, 2),
        "rate_by_followers_pct": round(rate_followers, 3) if rate_followers is not None else None,
        "rate_by_reach_pct": round(rate_reach, 3) if rate_reach is not None else None,
        "total_engagements": total_eng,
        "avg_reach": round(avg_reach, 1) if avg_reach is not None else None,
    }


def _http_get_json(url: str) -> dict[str, Any]:
    req = Request(url, headers={"User-Agent": "DoggoPokko-engagement-tool/1.0"})
    try:
        with urlopen(req, timeout=60) as resp:
            body = resp.read().decode("utf-8")
    except HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        raise RuntimeError(f"HTTP {e.code}: {err_body or e.reason}") from e
    except URLError as e:
        raise RuntimeError(str(e.reason)) from e
    data = json.loads(body)
    if isinstance(data, dict) and data.get("error"):
        err = data["error"]
        msg = err.get("message", json.dumps(err))
        raise RuntimeError(msg)
    return data


def _insights_to_map(insights: dict[str, Any] | None) -> dict[str, int]:
    if not insights or "data" not in insights:
        return {}
    out: dict[str, int] = {}
    for item in insights["data"]:
        name = item.get("name")
        vals = item.get("values") or []
        if not name or not vals:
            continue
        try:
            raw = vals[0].get("value")
            if raw is None:
                continue
            out[name] = int(raw)
        except (TypeError, ValueError):
            continue
    return out


def _apply_insight_map(pm: PostMetrics, m: dict[str, int]) -> None:
    if "reach" in m and pm.reach is None:
        pm.reach = m["reach"]
    if "saved" in m:
        pm.saves = m["saved"]
    if "impressions" in m and pm.impressions is None:
        pm.impressions = m["impressions"]
    if "engagement" in m and pm.engagement_total is None:
        pm.engagement_total = m["engagement"]
    elif "total_interactions" in m and pm.engagement_total is None:
        pm.engagement_total = m["total_interactions"]


def _item_to_post(item: dict[str, Any]) -> PostMetrics:
    pm = PostMetrics(
        post_id=str(item.get("id", "")),
        likes=int(item.get("like_count") or 0),
        comments=int(item.get("comments_count") or 0),
        saves=0,
        shares=0,
    )
    ins = item.get("insights")
    if isinstance(ins, dict):
        _apply_insight_map(pm, _insights_to_map(ins))
    return pm


def _fetch_media_insights_for_id(
    media_id: str,
    token: str,
    version: str,
    metrics: list[str],
) -> dict[str, int]:
    base = f"https://graph.facebook.com/{version}/{media_id}/insights"
    q: list[tuple[str, str]] = [("metric", m) for m in metrics]
    q.append(("access_token", token))
    url = f"{base}?{urlencode(q)}"
    payload = _http_get_json(url)
    return _insights_to_map(payload)


def _backfill_insights(
    posts: list[PostMetrics],
    raw_items: list[dict[str, Any]],
    token: str,
    version: str,
    delay_s: float,
) -> int:
    """Call GET /{media-id}/insights when nested insights on /media were missing."""
    calls = 0
    by_id = {str(it.get("id")): it for it in raw_items if it.get("id")}
    for pm in posts:
        if not pm.post_id:
            continue
        if pm.reach is not None and pm.engagement_total is not None:
            continue
        item = by_id.get(pm.post_id) or {}
        product = (item.get("media_product_type") or "").upper()
        media_type = (item.get("media_type") or "").upper()
        metric_sets: list[list[str]] = [
            ["reach", "engagement", "saved", "impressions"],
            ["reach", "total_interactions", "saved"],
            ["reach", "engagement", "saved"],
        ]
        if product == "REELS" or media_type == "VIDEO":
            metric_sets.insert(0, ["reach", "total_interactions", "saved", "impressions"])
        for ms in metric_sets:
            try:
                if delay_s > 0:
                    time.sleep(delay_s)
                m = _fetch_media_insights_for_id(pm.post_id, token, version, ms)
                calls += 1
                if m:
                    _apply_insight_map(pm, m)
                if pm.reach is not None and pm.engagement_total is not None:
                    break
            except RuntimeError:
                continue
    return calls


def _paginate_media(
    user_id: str,
    token: str,
    version: str,
    fields: str,
    page_limit: int,
    max_items: int,
) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    base = f"https://graph.facebook.com/{version}/{user_id}/media"
    params = {
        "fields": fields,
        "limit": str(min(max(page_limit, 1), 100)),
        "access_token": token,
    }
    url = f"{base}?{urlencode(params)}"
    while url and len(out) < max_items:
        payload = _http_get_json(url)
        batch = payload.get("data") or []
        out.extend(batch)
        if len(out) >= max_items:
            return out[:max_items]
        next_url = (payload.get("paging") or {}).get("next")
        url = next_url or ""
    return out


def fetch_graph_api_media_with_insights(
    user_id: str,
    token: str,
    max_posts: int = 50,
    version: str = "v21.0",
    insight_delay_s: float = 0.12,
) -> tuple[list[PostMetrics], dict[str, Any]]:
    meta: dict[str, Any] = {"version": version, "fields_used": None, "insight_backfill_calls": 0}

    field_candidates = [
        (
            "full",
            "id,media_type,media_product_type,caption,permalink,timestamp,like_count,comments_count,"
            "insights.metric(reach,engagement,saved,impressions,total_interactions)",
        ),
        (
            "standard",
            "id,media_type,media_product_type,caption,permalink,timestamp,like_count,comments_count,"
            "insights.metric(reach,engagement,saved)",
        ),
        (
            "basic",
            "id,media_type,media_product_type,caption,permalink,timestamp,like_count,comments_count",
        ),
    ]

    raw: list[dict[str, Any]] = []
    last_err: str | None = None
    for label, flds in field_candidates:
        try:
            raw = _paginate_media(user_id, token, version, flds, page_limit=25, max_items=max_posts)
            meta["fields_used"] = label
            break
        except RuntimeError as e:
            last_err = str(e)
            continue
    else:
        raise RuntimeError(last_err or "Failed to load media")

    posts = [_item_to_post(it) for it in raw]
    meta["insight_backfill_calls"] = _backfill_insights(
        posts, raw, token, version, insight_delay_s=insight_delay_s
    )

    meta["media_returned"] = len(raw)
    return posts, meta


def fetch_graph_api_user(user_id: str, token: str, version: str = "v21.0") -> dict[str, Any]:
    base = f"https://graph.facebook.com/{version}/{user_id}"
    params = {
        "fields": "username,name,followers_count,media_count",
        "access_token": token,
    }
    url = f"{base}?{urlencode(params)}"
    return _http_get_json(url)


def build_report_html(profile: ProfileSnapshot, rates: dict[str, Any]) -> str:
    template_path = Path(__file__).resolve().parent / "report_template.html"
    template = template_path.read_text(encoding="utf-8")
    rows_html = ""
    for p in profile.posts:
        eng = aggregate_engagement(p)
        reach_cell = str(p.reach) if p.reach is not None else "—"
        imp_cell = str(p.impressions) if p.impressions is not None else "—"
        rows_html += (
            f"<tr><td>{_escape(p.post_id)}</td><td>{p.likes}</td><td>{p.comments}</td>"
            f"<td>{p.saves}</td><td>{p.shares}</td><td>{reach_cell}</td><td>{imp_cell}</td><td>{eng}</td></tr>\n"
        )

    gen_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    display = profile.display_name or profile.username

    replacements = {
        "{{TITLE}}": _escape(f"Engagement — @{profile.username}"),
        "{{DISPLAY_NAME}}": _escape(display),
        "{{USERNAME}}": _escape(profile.username),
        "{{FOLLOWERS}}": str(profile.followers),
        "{{PERIOD}}": _escape(profile.period_label or "—"),
        "{{SOURCE_NOTE}}": _escape(profile.source_note),
        "{{POST_COUNT}}": str(rates["post_count"]),
        "{{TOTAL_ENG}}": str(rates["total_engagements"]),
        "{{AVG_ENG}}": str(rates["avg_engagement_per_post"]),
        "{{RATE_FOLLOWERS}}": _fmt_pct(rates["rate_by_followers_pct"]),
        "{{RATE_REACH}}": _fmt_pct(rates["rate_by_reach_pct"]),
        "{{AVG_REACH}}": str(rates["avg_reach"]) if rates["avg_reach"] is not None else "—",
        "{{ROWS}}": rows_html,
        "{{GENERATED_AT}}": gen_at,
    }
    out = template
    for k, v in replacements.items():
        out = out.replace(k, v)
    return out


def _escape(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def _fmt_pct(v: float | None) -> str:
    if v is None:
        return "— (add reach or followers)"
    return f"{v}%"


def main() -> None:
    load_env_file(_env_file_path())
    parser = argparse.ArgumentParser(
        description="Instagram engagement report generator",
        epilog="Loads a local .env file first (same folder as this script). "
        "Set DOTENV_FILE to override the path. Variables already in the environment are not overwritten.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--csv",
        type=Path,
        help="CSV with columns: post_id, likes, comments, saves, shares, reach (optional)",
    )
    parser.add_argument(
        "--json",
        type=Path,
        dest="json_config",
        help="JSON config with profile + posts (see config.example.json)",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("engagement_report.html"),
        help="Output HTML path",
    )
    parser.add_argument(
        "--followers",
        type=int,
        default=0,
        help="Follower count when using --csv (required for follower-based rate)",
    )
    parser.add_argument("--username", type=str, default="doggo_pokko", help="Handle for the report")
    parser.add_argument("--period", type=str, default="", help="Label for the reporting period")
    parser.add_argument(
        "--api",
        action="store_true",
        help="Fetch media + insights via Meta Graph API (env: INSTAGRAM_ACCESS_TOKEN, INSTAGRAM_USER_ID)",
    )
    parser.add_argument(
        "--graph-version",
        default=os.environ.get("INSTAGRAM_GRAPH_VERSION", "v21.0").strip() or "v21.0",
        help="Graph API version (default v21.0 or INSTAGRAM_GRAPH_VERSION)",
    )
    parser.add_argument(
        "--max-posts",
        type=int,
        default=50,
        help="Max media items to pull when using --api (default 50)",
    )
    parser.add_argument(
        "--insight-delay",
        type=float,
        default=0.12,
        help="Seconds between per-media /insights calls when backfilling (default 0.12)",
    )
    args = parser.parse_args()

    profile: ProfileSnapshot | None = None

    if args.api:
        token = os.environ.get("INSTAGRAM_ACCESS_TOKEN", "").strip()
        uid = os.environ.get("INSTAGRAM_USER_ID", "").strip()
        if not token or not uid:
            env_hint = _env_file_path()
            print(
                "Set INSTAGRAM_ACCESS_TOKEN and INSTAGRAM_USER_ID (Instagram Business Account ID).\n"
                f"Tip: add them to {env_hint} (see .env.example) or export in your shell.\n\n"
                "Meta app permissions: instagram_basic, instagram_manage_insights.\n"
                "Docs: https://developers.facebook.com/docs/instagram-platform/instagram-graph-api",
                file=sys.stderr,
            )
            sys.exit(1)
        ver = args.graph_version.strip() or "v21.0"
        user = fetch_graph_api_user(uid, token, version=ver)
        posts, meta = fetch_graph_api_media_with_insights(
            uid,
            token,
            max_posts=max(1, args.max_posts),
            version=ver,
            insight_delay_s=max(0.0, args.insight_delay),
        )
        src = (
            f"Meta Graph API {ver} (fields={meta.get('fields_used')}; "
            f"media={meta.get('media_returned')}; backfill_calls={meta.get('insight_backfill_calls')})"
        )
        profile = ProfileSnapshot(
            username=user.get("username") or args.username,
            display_name=user.get("name") or "",
            followers=int(user.get("followers_count") or 0),
            period_label=args.period or f"Recent {len(posts)} posts (Graph API)",
            posts=posts,
            source_note=src,
        )
    elif args.json_config:
        profile = load_json_config(args.json_config)
        if args.period:
            profile.period_label = args.period
    elif args.csv:
        posts = load_csv(args.csv)
        profile = ProfileSnapshot(
            username=args.username,
            followers=args.followers,
            period_label=args.period,
            posts=posts,
            source_note="CSV file",
        )
    else:
        parser.print_help()
        print(
            "\nExamples:\n"
            "  python engagement_tool.py --csv sample_posts.csv --followers 5000 --out report.html\n"
            "  INSTAGRAM_ACCESS_TOKEN=... INSTAGRAM_USER_ID=... python engagement_tool.py --api --out report.html",
            file=sys.stderr,
        )
        sys.exit(1)

    rates = compute_rates(profile)
    html = build_report_html(profile, rates)
    args.out.write_text(html, encoding="utf-8")
    print(f"Wrote {args.out.resolve()}")
    print(json.dumps(rates, indent=2))


if __name__ == "__main__":
    main()
