#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds engagement_report.html from dashboard_template.html + Meta Graph API.
# Requires: INSTAGRAM_ACCESS_TOKEN, INSTAGRAM_USER_ID in .env (see .env.example)

require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

ROOT = File.expand_path(__dir__)
ENV_PATH = File.join(ROOT, ".env")
TEMPLATE_PATH = File.join(ROOT, "dashboard_template.html")
OUT_PATH = File.join(ROOT, "engagement_report.html")
HERO_BG_REL = "assets/dogs/lab-yellow.jpg"
DOG_STRIP_RELS = [
  "assets/dogs/golden.jpg",
  "assets/dogs/pexels1.jpg",
  "assets/dogs/pexels2.jpg",
  "assets/dogs/lab-yellow.jpg"
].freeze
LOGO_FALLBACK = "assets/logo.svg"

def load_env_file(path)
  return unless File.file?(path)

  File.read(path, encoding: "UTF-8").each_line do |raw|
    line = raw.strip
    next if line.empty? || line.start_with?("#")
    line = line[7..].strip if line.start_with?("export ")
    next unless line.include?("=")

    key, val = line.split("=", 2).map(&:strip)
    next if key.nil? || key.empty?

    val = val[1..-2] if val.length >= 2 && %w[' "].include?(val[0]) && val[0] == val[-1]
    ENV[key] = val if ENV[key].nil?
  end
end

def http_get_json(url)
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = 30
  http.read_timeout = 120
  req = Net::HTTP::Get.new(uri.request_uri)
  req["User-Agent"] = "DoggoPokko-run-report/1.0"
  res = http.request(req)
  body = res.body.to_s
  raise "HTTP #{res.code}: #{body[0, 500]}" unless res.is_a?(Net::HTTPSuccess)

  data = JSON.parse(body)
  raise data["error"]["message"].to_s if data.is_a?(Hash) && data["error"]

  data
end

def insights_to_map(insights)
  return {} unless insights.is_a?(Hash) && insights["data"]

  out = {}
  insights["data"].each do |item|
    name = item["name"]
    vals = item["values"] || []
    next if name.nil? || vals.empty?

    raw = vals[0]["value"]
    next if raw.nil?

    out[name] = raw.to_i
  end
  out
end

def apply_insight_map(pm, m)
  pm[:reach] = m["reach"] if m["reach"] && pm[:reach].nil?
  pm[:saves] = m["saved"] if m.key?("saved")
  pm[:impressions] = m["impressions"] if m["impressions"] && pm[:impressions].nil?
  if m["views"] && (pm[:video_views].nil? || pm[:video_views].to_i.zero?)
    pm[:video_views] = m["views"].to_i
  end
  if m["engagement"] && pm[:engagement_total].nil?
    pm[:engagement_total] = m["engagement"].to_i
  elsif m["total_interactions"] && pm[:engagement_total].nil?
    pm[:engagement_total] = m["total_interactions"].to_i
  end
end

def item_to_post(item)
  cap = item["caption"].to_s
  pm = {
    post_id: item["id"].to_s,
    likes: (item["like_count"] || 0).to_i,
    comments: (item["comments_count"] || 0).to_i,
    saves: 0,
    shares: 0,
    reach: nil,
    impressions: nil,
    engagement_total: nil,
    video_views: nil,
    thumbnail_url: item["thumbnail_url"],
    permalink: item["permalink"],
    caption: cap[0, 280],
    media_type: item["media_type"],
    media_product_type: item["media_product_type"],
    timestamp: item["timestamp"]
  }
  ins = item["insights"]
  apply_insight_map(pm, insights_to_map(ins)) if ins.is_a?(Hash)
  pm
end

def fetch_media_insights_for_id(media_id, token, version, metrics)
  q = []
  metrics.each { |m| q << ["metric", m] }
  q << ["access_token", token]
  qs = URI.encode_www_form(q)
  url = "https://graph.facebook.com/#{version}/#{media_id}/insights?#{qs}"
  insights_to_map(http_get_json(url))
end

def backfill_insights(posts, raw_items, token, version, delay_s)
  calls = 0
  by_id = {}
  raw_items.each { |it| by_id[it["id"].to_s] = it if it["id"] }
  posts.each do |pm|
    next if pm[:post_id].to_s.empty?
    next if !pm[:reach].nil? && !pm[:engagement_total].nil?

    item = by_id[pm[:post_id]] || {}
    product = (item["media_product_type"] || "").upcase
    mtype = (item["media_type"] || "").upcase
    metric_sets = [
      %w[reach engagement saved impressions],
      %w[reach total_interactions saved],
      %w[reach engagement saved]
    ]
    metric_sets.unshift(%w[reach total_interactions saved impressions]) if product == "REELS" || mtype == "VIDEO"
    metric_sets.each do |ms|
      begin
        sleep(delay_s) if delay_s > 0
        m = fetch_media_insights_for_id(pm[:post_id], token, version, ms)
        calls += 1
        apply_insight_map(pm, m) unless m.empty?
        break if !pm[:reach].nil? && !pm[:engagement_total].nil?
      rescue StandardError
        next
      end
    end
  end
  calls
end

def backfill_reel_views(posts, _raw_items, token, version, delay_s)
  calls = 0
  posts.each do |pm|
    next if pm[:post_id].to_s.empty?
    next unless video_or_reel?(pm)
    next if pm[:video_views].to_i > 0

    begin
      sleep(delay_s) if delay_s > 0
      m = fetch_media_insights_for_id(pm[:post_id], token, version, %w[views])
      calls += 1
      pm[:video_views] = m["views"].to_i if m["views"]
    rescue StandardError
      begin
        sleep(delay_s) if delay_s > 0
        m2 = fetch_media_insights_for_id(pm[:post_id], token, version, %w[plays])
        calls += 1
        pm[:video_views] = m2["plays"].to_i if m2["plays"]
      rescue StandardError
        next
      end
    end
  end
  calls
end

def paginate_media(user_id, token, version, fields, page_limit, max_items)
  out = []
  limit = [[page_limit, 1].max, 100].min
  params = {
    "fields" => fields,
    "limit" => limit.to_s,
    "access_token" => token
  }
  qs = URI.encode_www_form(params)
  url = "https://graph.facebook.com/#{version}/#{user_id}/media?#{qs}"
  while url && out.length < max_items
    payload = http_get_json(url)
    batch = payload["data"] || []
    out.concat(batch)
    break if out.length >= max_items

    url = (payload["paging"] || {})["next"]
    url = nil if url.to_s.empty?
  end
  out[0, max_items]
end

def fetch_graph_api_media_with_insights(user_id, token, max_posts, version, insight_delay_s)
  meta = { "version" => version, "fields_used" => nil, "insight_backfill_calls" => 0 }
  candidates = [
    [
      "full",
      "id,media_type,media_product_type,caption,permalink,timestamp,thumbnail_url,like_count,comments_count," \
      "insights.metric(reach,engagement,saved,impressions,total_interactions,views)"
    ],
    [
      "standard",
      "id,media_type,media_product_type,caption,permalink,timestamp,thumbnail_url,like_count,comments_count," \
      "insights.metric(reach,engagement,saved,views)"
    ],
    [
      "basic",
      "id,media_type,media_product_type,caption,permalink,timestamp,thumbnail_url,like_count,comments_count"
    ]
  ]
  raw = []
  last_err = nil
  candidates.each do |label, flds|
    begin
      raw = paginate_media(user_id, token, version, flds, 25, max_posts)
      meta["fields_used"] = label
      break
    rescue StandardError => e
      last_err = e.message
      next
    end
  end
  raise last_err || "Failed to load media" if meta["fields_used"].nil?

  posts = raw.map { |it| item_to_post(it) }
  meta["insight_backfill_calls"] = backfill_insights(posts, raw, token, version, insight_delay_s)
  meta["views_backfill_calls"] = backfill_reel_views(posts, raw, token, version, insight_delay_s)
  meta["media_returned"] = raw.length
  [posts, meta, raw]
end

def fetch_graph_api_user(user_id, token, version)
  qs = URI.encode_www_form(
    "fields" => "username,name,followers_count,media_count,profile_picture_url",
    "access_token" => token
  )
  http_get_json("https://graph.facebook.com/#{version}/#{user_id}?#{qs}")
end

def fetch_ig_insights(uid, token, version, params)
  qs = URI.encode_www_form(params.merge("access_token" => token))
  http_get_json("https://graph.facebook.com/#{version}/#{uid}/insights?#{qs}")
rescue StandardError
  nil
end

def extract_breakdown(insights_payload, metric_name)
  return nil unless insights_payload.is_a?(Hash) && insights_payload["data"]

  row = insights_payload["data"].find { |d| d["name"] == metric_name }
  return nil unless row && row["values"] && row["values"][0]

  row["values"][0]["value"]
end

def parse_follower_avg_daily(insights_payload)
  return [nil, nil] unless insights_payload.is_a?(Hash) && insights_payload["data"]

  row = insights_payload["data"].find { |d| d["name"] == "follower_count" }
  return [nil, nil] unless row && row["values"]

  vals = row["values"]
  return [nil, nil] if vals.length < 2

  nums = vals.map { |v| (v["value"] || 0).to_i }
  deltas = []
  (1...nums.length).each { |i| deltas << (nums[i] - nums[i - 1]) }
  avg = deltas.empty? ? nil : (deltas.sum.to_f / deltas.length).round(1)
  note = "Based on #{vals.length} recent days."
  [avg, note]
end

def render_demographics_bar_block(title, hash)
  return "" unless hash.is_a?(Hash) && !hash.empty?

  sorted = hash.sort_by { |_, v| -v.to_f }
  top = sorted.first(6)
  maxv = top.map { |_, v| v.to_f }.max
  maxv = 1.0 if maxv < 1
  out = %(<p style="margin:0 0 0.75rem;color:#fff;font-weight:600">#{title}</p>)
  top.each do |k, v|
    pct = (v.to_f / maxv * 100).round(1)
    out << %(<div class="bar-row"><span style="min-width:100px;color:var(--nf-muted);font-size:0.78rem">#{escape_html(k.to_s)}</span><div class="bar"><i style="width:#{pct}%"></i></div><span style="min-width:36px;text-align:right;font-size:0.78rem">#{v}</span></div>)
  end
  out
end

def build_demographics_html(uid, token, version)
  ga = fetch_ig_insights(uid, token, version,
                         "metric" => "audience_gender_age", "period" => "lifetime", "metric_type" => "total_value")
  co = fetch_ig_insights(uid, token, version,
                         "metric" => "audience_country", "period" => "lifetime", "metric_type" => "total_value")
  gav = extract_breakdown(ga, "audience_gender_age")
  cov = extract_breakdown(co, "audience_country")
  parts = +""
  parts << render_demographics_bar_block("Gender &amp; age", gav) if gav.is_a?(Hash)
  parts << render_demographics_bar_block("Top countries", cov) if cov.is_a?(Hash)
  parts
end

def video_or_reel?(p)
  mt = (p[:media_type] || "").upcase
  mp = (p[:media_product_type] || "").upcase
  mt == "VIDEO" || %w[REELS REEL].include?(mp)
end

def viral_score(p)
  v = (p[:video_views] || 0).to_i
  likes = p[:likes].to_i
  comments = p[:comments].to_i
  saves = p[:saves].to_i
  shares = p[:shares].to_i
  v + (likes * 5) + (comments * 8) + (saves * 6) + (shares * 12)
end

def post_er_vs_followers(p, followers)
  return nil if followers.to_i <= 0

  ((aggregate_engagement(p).to_f / followers) * 100.0).round(3)
end

def post_er_vs_reach(p)
  r = p[:reach].to_i
  return nil if r <= 0

  ((aggregate_engagement(p).to_f / r) * 100.0).round(3)
end

def number_with_commas(n)
  n.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
end

def relative_time_ago(ts)
  s = ts.to_s.strip
  return "" if s.empty?

  t = Time.parse(s).utc
  now = Time.now.utc
  diff = (now - t).to_i
  return "just now" if diff < 60
  return "#{diff / 60} min ago" if diff < 3600
  return "#{diff / 3600}h ago" if diff < 86_400

  days = diff / 86_400
  return "#{days}d ago" if days < 30
  months = days / 30
  return "#{months} mo ago" if months < 12

  "#{days / 365} yr ago"
rescue ArgumentError, TypeError
  ""
end

def format_ig_date_long(ts)
  s = ts.to_s.strip
  return "" if s.empty?

  Time.parse(s).utc.strftime("%A, %B %d, %Y")
rescue ArgumentError, TypeError
  ""
end

def format_ig_date_short(ts)
  s = ts.to_s.strip
  return "—" if s.empty?

  Time.parse(s).utc.strftime("%b %d, %Y")
rescue ArgumentError, TypeError
  "—"
end

def build_top5_json(reels_sorted_by_views, followers)
  reels_sorted_by_views.first(5).map.with_index do |p, i|
    eng = aggregate_engagement(p)
    lbl = (p[:media_product_type] || p[:media_type] || "VIDEO").to_s
    {
      rank: i + 1,
      engagement: eng,
      thumbnail: p[:thumbnail_url].to_s,
      permalink: p[:permalink].to_s,
      caption: safe_caption(p[:caption]),
      label: lbl,
      posted_at: p[:timestamp].to_s,
      posted_label: format_ig_date_long(p[:timestamp]),
      relative_ago: relative_time_ago(p[:timestamp]),
      video_views: (p[:video_views] || 0).to_i,
      post_er_followers_pct: post_er_vs_followers(p, followers),
      post_er_reach_pct: post_er_vs_reach(p)
    }
  end
end

def build_reels_grid_html(reels_sorted_by_views, followers)
  reels_sorted_by_views.map do |p|
    er_r = post_er_vs_reach(p)
    er_f = post_er_vs_followers(p, followers)
    er_show = if er_r
                "#{er_r}% (reach)"
              elsif er_f
                "#{er_f}% (followers)"
              else
                "—"
              end
    views = (p[:video_views] || 0).to_i
    views_line = views.positive? ? number_with_commas(views) : "—"
    cap = escape_html(safe_caption(p[:caption])[0, 140])
    thumb = p[:thumbnail_url].to_s
    img = thumb.empty? ? '<div class="reel-thumb-ph"></div>' : %{<img src="#{escape_html(thumb)}" alt="" loading="lazy" />}
    link = p[:permalink].to_s
    link_h = link.empty? ? "" : %{<a class="reel-card-link" href="#{escape_html(link)}" target="_blank" rel="noopener">View on Instagram →</a>}
    date_line = "#{escape_html(format_ig_date_short(p[:timestamp]))} · #{escape_html(relative_time_ago(p[:timestamp]))}"
    <<~HTML
      <article class="reel-card">
        <div class="reel-thumb-wrap">
          <span class="reel-badge">Video</span>
          #{img}
        </div>
        <div class="reel-card-body">
          <div class="reel-meta-row">
            <span class="reel-date">#{date_line}</span>
            <span class="reel-er">#{escape_html(er_show)}</span>
          </div>
          <div class="reel-stats">#{number_with_commas(p[:likes])} likes · #{number_with_commas(p[:comments])} comments · #{views_line} views</div>
          <p class="reel-cap">#{cap}</p>
          #{link_h}
        </div>
      </article>
    HTML
  end.join("\n")
end

def build_sample_calculation_html(sample_post, followers)
  return "" unless sample_post

  eng = aggregate_engagement(sample_post)
  l = sample_post[:likes].to_i
  c = sample_post[:comments].to_i
  sv = sample_post[:saves].to_i
  sh = sample_post[:shares].to_i
  sum_parts = l + c + sv + sh
  bundled = sample_post[:engagement_total]
  meta_line = if bundled && bundled.to_i != sum_parts
                "<p>Meta also returned <strong>#{number_with_commas(bundled.to_i)}</strong> as bundled <code>engagement</code> / <code>total_interactions</code> — we use that for rates when present (it can include profile actions and other signals beyond the sum above).</p>"
              elsif bundled
                "<p>Bundled <code>engagement</code> from Meta matches the sum above.</p>"
              else
                "<p>No bundled <code>engagement</code> insight — total interactions = sum of components.</p>"
              end
  er_f = post_er_vs_followers(sample_post, followers)
  er_r = post_er_vs_reach(sample_post)
  reach = sample_post[:reach]
  er_f_s = er_f ? "#{er_f}%" : "—"
  reach_block = if reach.to_i > 0 && er_r
                  "<p><strong>Engagement rate vs reach</strong> (common market standard when reach exists): #{number_with_commas(eng)} ÷ #{number_with_commas(reach)} × 100 = <strong>#{er_r}%</strong></p>"
                else
                  "<p><em>Reach not returned for this post — use vs followers below, or connect media insights permissions for reach-based ER.</em></p>"
                end
  <<~HTML
    <div class="sample-block">
      <h3>Worked example — one post</h3>
      <p class="sample-id">Post …#{escape_html(sample_post[:post_id].to_s[-8, 8] || '')} · #{escape_html(format_ig_date_short(sample_post[:timestamp]))}</p>
      <p><strong>Components</strong> (when not using bundled insight): likes + comments + saves + shares.</p>
      <p>#{number_with_commas(l)} + #{number_with_commas(c)} + #{number_with_commas(sv)} + #{number_with_commas(sh)} = <strong>#{number_with_commas(sum_parts)}</strong></p>
      #{meta_line}
      <p><strong>Total interactions used for rates</strong>: <strong>#{number_with_commas(eng)}</strong></p>
      <p><strong>Engagement rate vs followers</strong> (benchmarking across account sizes): #{number_with_commas(eng)} ÷ #{number_with_commas(followers)} × 100 = <strong>#{er_f_s}</strong></p>
      #{reach_block}
    </div>
  HTML
end

def safe_caption(s)
  s.to_s.gsub(/[\u0000-\u001F]/, " ").gsub(%r{</?script}i, " script")[0, 400]
end

def build_post_rows(posts, include_reach:, include_impressions:)
  rows = +""
  posts.each do |p|
    eng = aggregate_engagement(p)
    reach_cell = p[:reach].nil? ? "—" : p[:reach].to_s
    imp_cell = p[:impressions].nil? ? "—" : p[:impressions].to_s
    thumb = p[:thumbnail_url].to_s
    thumb_html = if thumb.empty?
                   '<span class="thumb thumb-ph" aria-hidden="true"></span>'
                 else
                   %{<img class="thumb" src="#{escape_html(thumb)}" alt="" loading="lazy" />}
                 end
    mlabel = [p[:media_product_type], p[:media_type]].compact.join(" · ")
    posted = format_ig_date_short(p[:timestamp])
    link_html = if p[:permalink].to_s.empty?
                  "—"
                else
                  %{<a href="#{escape_html(p[:permalink])}" target="_blank" rel="noopener" class="table-link">View</a>}
                end
    extra = +""
    extra << "<td>#{reach_cell}</td>" if include_reach
    extra << "<td>#{imp_cell}</td>" if include_impressions
    rows << "<tr><td>#{thumb_html}</td><td>#{escape_html(mlabel)}</td><td>#{escape_html(posted)}</td><td>#{p[:likes]}</td><td>#{p[:comments]}</td>" \
            "<td>#{p[:saves]}</td>#{extra}<td>#{eng}</td><td>#{link_html}</td></tr>\n"
  end
  rows
end

def build_table_header(include_reach:, include_impressions:)
  th = +"<tr><th>Preview</th><th>Type</th><th>Posted (UTC)</th><th>Likes</th><th>Comments</th><th>Saves</th>"
  th << "<th>Reach</th>" if include_reach
  th << "<th>Impr.</th>" if include_impressions
  th << "<th>Total eng.</th><th>Link</th></tr>"
  th
end

def build_dog_strip_html
  DOG_STRIP_RELS.map do |rel|
    %{<div class="dog-strip-item"><img src="#{escape_html(rel)}" alt="" width="400" height="300" loading="lazy" decoding="async" /></div>}
  end.join
end

def build_kpi_row_html(rates, avg_followers_day, follower_note, reel_stats)
  chunks = []
  chunks << %(<div class="kpi hero-metric"><div class="label">Engagement rate (sample)</div><div class="num">#{fmt_pct_clean(rates[:rate_by_followers_pct])}</div><div class="meta-line">Avg interactions ÷ followers × 100</div></div>)
  if rates[:rate_by_reach_pct]
    chunks << %(<div class="kpi"><div class="label">Engagement rate (reach)</div><div class="num">#{fmt_pct_clean(rates[:rate_by_reach_pct])}</div><div class="meta-line">When reach exists per post</div></div>)
  end
  chunks << %(<div class="kpi"><div class="label">Avg engagement / post</div><div class="num">#{rates[:avg_engagement_per_post]}</div></div>)
  chunks << %(<div class="kpi"><div class="label">Avg likes (reels)</div><div class="num">#{reel_stats[:avg_likes]}</div></div>)
  chunks << %(<div class="kpi"><div class="label">Avg comments (reels)</div><div class="num">#{reel_stats[:avg_comments]}</div></div>)
  if reel_stats[:show_plays]
    chunks << %(<div class="kpi"><div class="label">Avg plays / views (reels)</div><div class="num">#{reel_stats[:avg_plays]}</div></div>)
  end
  if avg_followers_day
    meta = (follower_note && !follower_note.strip.empty?) ? %(<div class="meta-line">#{escape_html(follower_note)}</div>) : ""
    chunks << %(<div class="kpi"><div class="label">Avg new followers / day</div><div class="num">#{fmt_followers_per_day(avg_followers_day)}</div>#{meta}</div>)
  end
  chunks.join
end

def build_audience_section_html(demographics_html)
  d = demographics_html.to_s.strip
  return "" if d.empty?

  %(<h2 class="section-title">Audience</h2><div class="demo-block">#{d}</div>)
end

def build_sidebar_formulas_html(has_reach:, has_followers_daily:, has_demographics:)
  parts = []
  parts << "<dt>Interactions (per post)</dt><dd>Likes + comments + saves + shares. If Meta returns an <code>engagement</code> insight, that value is used instead.</dd>"
  parts << "<dt>Engagement rate vs followers</dt><dd>Total interactions ÷ follower count × 100 — common for comparing accounts of different sizes.</dd>"
  parts << "<dt>Engagement rate vs reach</dt><dd>Total interactions ÷ reach × 100 — preferred when reach is available (closer to ad/organic delivery).</dd>" if has_reach
  parts << "<dt>Sample engagement rate</dt><dd>Sum of interactions in this sample ÷ number of posts ÷ followers × 100 (headline KPI).</dd>"
  parts << "<dt>Top 5 by views</dt><dd>Top 5 uses reels from a wide account fetch, ranked by <strong>plays/views only</strong> (not engagement). KPI numbers use your most recent posts only (see report footnote).</dd>"
  parts << "<dt>Avg new followers / day</dt><dd>From daily follower snapshots when Meta returns them.</dd>" if has_followers_daily
  parts << "<dt>Audience breakdown</dt><dd>When Instagram provides audience insights.</dd>" if has_demographics
  "<dl>#{parts.join}</dl>"
end

def report_generated_long
  t = Time.now.utc
  "#{t.strftime('%A')}, #{t.strftime('%B')} #{t.day}, #{t.year} · #{t.strftime('%H:%M')} UTC"
end

def aggregate_engagement(p)
  return p[:engagement_total] unless p[:engagement_total].nil?

  p[:likes] + p[:comments] + p[:saves] + p[:shares]
end

def post_timestamp(p)
  Time.parse(p[:timestamp].to_s)
rescue ArgumentError, TypeError
  Time.at(0)
end

# Top 5: strictly by plays/views (highest first). Ties: stable id.
def sort_reels_by_views_only(reels)
  reels.sort_by { |p| [-(p[:video_views] || 0).to_i, p[:post_id].to_s] }
end

def compute_rates(_username, followers, _period_label, posts, _source_note)
  n = posts.length
  if n.zero?
    return {
      post_count: 0,
      avg_engagement_per_post: 0.0,
      rate_by_followers_pct: nil,
      rate_by_reach_pct: nil,
      total_engagements: 0,
      avg_reach: nil
    }
  end
  total_eng = posts.sum { |p| aggregate_engagement(p) }
  avg_eng = total_eng.to_f / n
  rate_followers = nil
  rate_followers = ((avg_eng / followers) * 100.0).round(3) if followers.to_i > 0
  reaches = posts.map { |p| p[:reach] }.compact.select { |r| r > 0 }
  rate_reach = nil
  avg_reach = nil
  unless reaches.empty?
    avg_reach = (reaches.sum.to_f / reaches.length).round(1)
    total_reach = reaches.sum
    rate_reach = ((total_eng.to_f / total_reach) * 100.0).round(3) if total_reach > 0
  end
  {
    post_count: n,
    avg_engagement_per_post: avg_eng.round(2),
    rate_by_followers_pct: rate_followers,
    rate_by_reach_pct: rate_reach,
    total_engagements: total_eng,
    avg_reach: avg_reach
  }
end

def escape_html(s)
  s.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
end

def fmt_pct_clean(v)
  return "—" if v.nil?

  "#{v}%"
end

def fmt_followers_per_day(v)
  return "—" if v.nil?

  sign = v >= 0 ? "+" : ""
  "#{sign}#{v} / day"
end

def build_dashboard_html(username, display_name, followers, period_label, rates, top5,
                          logo_src, logo_extra_class, kpi_row_html, audience_section_html,
                          table_header_row, post_rows, sidebar_formulas_html, reels_grid_html,
                          sample_calc_html)
  template = File.read(TEMPLATE_PATH, encoding: "UTF-8")
  gen_at = report_generated_long
  disp = display_name.to_s.empty? ? username : display_name
  top5_json = JSON.generate(top5).gsub("</", "<\\/")
  site_domain = ENV["SITE_DOMAIN"].to_s.strip
  page_title = if site_domain.empty?
                 "Doggo Pokko — @#{username}"
               else
                 "Doggo Pokko — @#{username} · #{site_domain}"
               end
  template
    .gsub("{{TITLE}}", escape_html(page_title))
    .gsub("{{LOGO_SRC}}", escape_html(logo_src))
    .gsub("{{LOGO_EXTRA_CLASS}}", logo_extra_class)
    .gsub("{{HERO_BG_URL}}", HERO_BG_REL)
    .gsub("{{DISPLAY_NAME}}", escape_html(disp))
    .gsub("{{USERNAME}}", escape_html(username))
    .gsub("{{FOLLOWERS}}", followers.to_s)
    .gsub("{{PERIOD_LABEL}}", escape_html(period_label))
    .gsub("{{REPORT_DATE_DISPLAY}}", escape_html(gen_at))
    .gsub("{{KPI_ROW_HTML}}", kpi_row_html)
    .gsub("{{REELS_GRID_HTML}}", reels_grid_html)
    .gsub("{{AUDIENCE_SECTION}}", audience_section_html)
    .gsub("{{DOG_STRIP_HTML}}", build_dog_strip_html)
    .gsub("{{TABLE_HEADER_ROW}}", table_header_row)
    .gsub("{{SIDEBAR_FORMULAS}}", sidebar_formulas_html)
    .gsub("{{SAMPLE_CALC_HTML}}", sample_calc_html)
    .gsub("{{TOP5_JSON}}", top5_json)
    .gsub("{{POST_ROWS}}", post_rows)
    .gsub("{{GENERATED_AT}}", escape_html(gen_at))
end

# --- main ---
load_env_file(ENV["DOTENV_FILE"] ? File.expand_path(ENV["DOTENV_FILE"]) : ENV_PATH)

token = ENV["INSTAGRAM_ACCESS_TOKEN"].to_s.strip
uid = ENV["INSTAGRAM_USER_ID"].to_s.strip
version = (ENV["INSTAGRAM_GRAPH_VERSION"] || "v21.0").strip
version = "v21.0" if version.empty?
# How many media items to pull from the account (paginated). Higher = Top 5 reflects true hits (e.g. 5M+ views).
# Default 500 when unset. If only legacy MAX_POSTS is set, that value is used.
max_media_fetch = if !ENV["MAX_MEDIA_FETCH"].to_s.strip.empty?
                      ENV["MAX_MEDIA_FETCH"].to_i
                    elsif !ENV["MAX_POSTS"].to_s.strip.empty?
                      ENV["MAX_POSTS"].to_i
                    else
                      500
                    end
max_media_fetch = 500 if max_media_fetch < 1
max_media_fetch = 5000 if max_media_fetch > 5000
# Recent posts used for KPI + table rows (keeps rates meaningful).
kpi_sample = (ENV["KPI_SAMPLE_POSTS"] || "50").to_i
kpi_sample = 50 if kpi_sample < 1
kpi_sample = 500 if kpi_sample > 500
table_posts_n = (ENV["TABLE_POSTS"] || "50").to_i
table_posts_n = 50 if table_posts_n < 1
table_posts_n = 500 if table_posts_n > 500
reels_grid_n = (ENV["REELS_GRID_LIMIT"] || "50").to_i
reels_grid_n = 50 if reels_grid_n < 1
reels_grid_n = 200 if reels_grid_n > 200
insight_delay = (ENV["INSIGHT_DELAY"] || "0.12").to_f
insight_delay = 0.12 if insight_delay.negative?

if token.empty? || uid.empty?
  warn "Set INSTAGRAM_ACCESS_TOKEN and INSTAGRAM_USER_ID in #{ENV_PATH}"
  exit 1
end

user = fetch_graph_api_user(uid, token, version)
posts, meta, = fetch_graph_api_media_with_insights(uid, token, max_media_fetch, version, insight_delay)

username = user["username"] || "unknown"
display_name = user["name"].to_s
followers = (user["followers_count"] || 0).to_i

posts_recent_first = posts.sort_by { |p| post_timestamp(p) }.reverse
kpi_subset = posts_recent_first.first([kpi_sample, posts.length].min)
rates = compute_rates(username, followers, "", kpi_subset, "")

follower_raw = fetch_ig_insights(uid, token, version,
                                 "metric" => "follower_count", "period" => "day", "metric_type" => "total_value")
avg_fd, fd_note = parse_follower_avg_daily(follower_raw)

demographics_html = build_demographics_html(uid, token, version)
has_demo = !demographics_html.strip.empty?

rv = posts.select { |p| video_or_reel?(p) }
reels_by_views = sort_reels_by_views_only(rv)
table_subset = posts_recent_first.first([table_posts_n, posts.length].min)
posts_sorted = table_subset.sort_by { |p| [-(p[:video_views] || 0).to_i, -viral_score(p)] }

avg_likes = rv.empty? ? 0 : (rv.sum { |p| p[:likes] }.to_f / rv.length).round
avg_comments = rv.empty? ? 0 : (rv.sum { |p| p[:comments] }.to_f / rv.length).round
sum_views = rv.sum { |p| (p[:video_views] || 0).to_i }
show_plays = sum_views.positive?
avg_plays = !show_plays || rv.empty? ? "—" : (sum_views.to_f / rv.length).round
reel_stats = {
  avg_likes: avg_likes,
  avg_comments: avg_comments,
  avg_plays: avg_plays,
  show_plays: show_plays
}

top5 = build_top5_json(reels_by_views, followers)
reels_for_grid = reels_by_views.first([reels_grid_n, reels_by_views.length].min)
reels_grid_html = if reels_for_grid.empty?
                    '<p class="reels-empty">No Reels or videos in this sample.</p>'
                  else
                    build_reels_grid_html(reels_for_grid, followers)
                  end
sample_calc_html = build_sample_calculation_html(reels_by_views.first || posts_sorted.first, followers)

include_reach = posts.any? { |p| !p[:reach].nil? }
include_imp = posts.any? { |p| !p[:impressions].nil? }
post_rows = build_post_rows(posts_sorted, include_reach: include_reach, include_impressions: include_imp)
table_header_row = build_table_header(include_reach: include_reach, include_impressions: include_imp)

logo_url = user["profile_picture_url"].to_s.strip
logo_src = logo_url.empty? ? LOGO_FALLBACK : logo_url
logo_extra_class = logo_url.empty? ? "" : " logo-avatar"

kpi_row_html = build_kpi_row_html(rates, avg_fd, fd_note, reel_stats)
audience_section_html = build_audience_section_html(demographics_html)
sidebar_formulas = build_sidebar_formulas_html(
  has_reach: !rates[:rate_by_reach_pct].nil?,
  has_followers_daily: !avg_fd.nil?,
  has_demographics: has_demo
)

period_label = "Fetched #{posts.length} media items for ranking · Top 5 reels = highest views on account (from this fetch). " \
               "Headline KPIs use your #{kpi_subset.length} most recent posts. Table shows #{table_subset.length} most recent. " \
               "API: #{meta['fields_used']}; media=#{meta['media_returned']}; insight backfill=#{meta['insight_backfill_calls']}; views backfill=#{meta['views_backfill_calls']}."

html = build_dashboard_html(
  username, display_name, followers, period_label, rates, top5,
  logo_src, logo_extra_class, kpi_row_html, audience_section_html,
  table_header_row, post_rows, sidebar_formulas, reels_grid_html, sample_calc_html
)

File.write(OUT_PATH, html, encoding: "UTF-8")
puts "Wrote #{OUT_PATH}"
puts JSON.pretty_generate(
  post_count: rates[:post_count],
  avg_engagement_per_post: rates[:avg_engagement_per_post],
  rate_by_followers_pct: rates[:rate_by_followers_pct],
  rate_by_reach_pct: rates[:rate_by_reach_pct],
  total_engagements: rates[:total_engagements],
  avg_reach: rates[:avg_reach]
)
