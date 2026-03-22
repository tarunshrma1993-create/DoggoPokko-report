#!/usr/bin/env ruby
# frozen_string_literal: true

# Upload dist/ to GoDaddy (or any FTP) — set in .env:
#   GODADDY_FTP_HOST, GODADDY_FTP_USER, GODADDY_FTP_PASSWORD
#   GODADDY_FTP_REMOTE_DIR=public_html   (optional)
#   GODADDY_FTP_PORT=21                  (optional)

require "net/ftp"
require "socket"

ROOT = File.expand_path(__dir__)
ENV_PATH = File.join(ROOT, ".env")
DIST = File.join(ROOT, "dist")

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

def upload_tree(ftp, local_dir, counts)
  Dir.entries(local_dir).each do |name|
    next if name == "." || name == ".."

    local = File.join(local_dir, name)
    if File.directory?(local)
      begin
        ftp.mkdir(name)
      rescue Net::FTPPermError
        # already there
      end
      ftp.chdir(name)
      upload_tree(ftp, local, counts)
      ftp.chdir("..")
    else
      ftp.putbinaryfile(local, name)
      counts[:files] += 1
    end
  end
end

load_env_file(ENV["DOTENV_FILE"] ? File.expand_path(ENV["DOTENV_FILE"]) : ENV_PATH)

host = ENV["GODADDY_FTP_HOST"].to_s.strip
user = ENV["GODADDY_FTP_USER"].to_s.strip
pass = ENV["GODADDY_FTP_PASSWORD"].to_s.strip
remote = ENV["GODADDY_FTP_REMOTE_DIR"].to_s.strip
remote = "public_html" if remote.empty?

port = (ENV["GODADDY_FTP_PORT"] || "21").to_i
port = 21 if port < 1 || port > 65_535

if host.empty? || user.empty? || pass.empty?
  warn "Skipping FTP upload: set GODADDY_FTP_HOST, GODADDY_FTP_USER, GODADDY_FTP_PASSWORD in .env"
  warn "(Get these from GoDaddy → cPanel → FTP Accounts, or Hosting → FTP.)"
  exit 0
end

unless File.directory?(DIST) && File.file?(File.join(DIST, "index.html"))
  warn "Missing dist/ — run: ./package_for_site.sh"
  exit 1
end

puts "Connecting to #{host}:#{port} …"
counts = { files: 0 }
ftp = nil
begin
  ftp = Net::FTP.new
  ftp.connect(host, port)
  ftp.login(user, pass)
  ftp.passive = true
  begin
    ftp.chdir(remote)
  rescue Net::FTPPermError => e
    warn "Could not chdir to #{remote.inspect}: #{e.message}"
    warn "Try GODADDY_FTP_REMOTE_DIR=/home/YOURUSER/public_html (see cPanel → File Manager path)."
    exit 1
  end
  puts "Uploading #{DIST} → …/#{remote}/"
  upload_tree(ftp, DIST, counts)
  puts "Uploaded #{counts[:files]} files. Open your site (e.g. https://doggopokko.com/) to verify."
rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, SocketError => e
  warn "Network error (#{e.class}): #{e.message}"
  warn "Check GODADDY_FTP_HOST and firewall; GoDaddy often uses hostname like ftp.doggopokko.com"
  exit 1
rescue Net::FTPError => e
  warn "FTP error: #{e.message}"
  warn "If login fails, reset the FTP password in cPanel → FTP Accounts."
  exit 1
ensure
  ftp&.close
end
