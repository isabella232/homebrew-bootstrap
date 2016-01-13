#!/usr/bin/env ruby
# Creates and closes issues on a project.
close = !!ARGV.delete("--close")
user_repo = ARGV.shift
message = ARGV.shift

if user_repo.to_s.empty? || message.to_s.empty?
  abort "Usage: brew report-issue [--close] <user/repo> <message> [<STDIN piped body>]"
end

unless close
  abort "Error: the issue/comment body should be piped over STDIN!" if STDIN.tty?
  body = STDIN.read
end

github_credentials=`printf "protocol=https\nhost=github.com\n" | git credential fill 2>/dev/null`
/username=(?<github_username>.+)/ =~ github_credentials
/password=(?<github_password>.+)/ =~ github_credentials
github_username ||= ENV["BOXEN_GITHUB_LOGIN"]
github_username ||= `git config github.user`.chomp

if github_username.to_s.empty?
  abort <<-EOS
Error: your GitHub username is not set! Set it by running Strap:
  https://strap.githubapp.com
EOS
end
@github_username = github_username

if github_password.to_s.empty?
  abort <<-EOS
Error: your GitHub password is not set! Set it by running Strap:
  https://strap.githubapp.com
EOS
end
@github_password = github_password

require "net/http"
require "json"

def http_request type, url, body=nil
  uri = URI url
  request = if type == :post
    post_request = Net::HTTP::Post.new uri
    post_request.body = body
    post_request
  elsif type == :get
    Net::HTTP::Get.new uri
  end
  return unless request
  request.basic_auth @github_username, @github_password
  Net::HTTP.start uri.hostname, uri.port, use_ssl: true  do |http|
    http.request request
  end
end

def response_check response, action
  return if response.is_a? Net::HTTPSuccess
  STDERR.puts "Error: failed to #{action}!"
  unless response.body.empty?
    failure = JSON.parse response.body
    STDERR.puts "--\n#{response.code}: #{failure["message"] }"
  end
  exit 1
end

def json_escape string
  JSON.generate string, quirks_mode: true
end

def create_issue user_repo, title, body
  title_json_string = json_escape title
  body_json_string = json_escape body.chomp
  new_issue_json = <<-EOS
    {
      "title": #{title_json_string},
      "body":  #{body_json_string}
    }
  EOS
  issues_url = "https://api.github.com/repos/#{user_repo}/issues"
  response = http_request :post, issues_url, new_issue_json
  response_check response, "create issue (#{issues_url})"
  issue = JSON.parse response.body
  puts "Created issue: #{issue["html_url"]}"
  issue
end

def comment_issue issue, comment_body, options={}
  comments_url = issue["comments_url"]
  body_json_string = json_escape comment_body.chomp
  issue_comment_json = "{ \"body\": #{body_json_string} }"
  response = http_request :post, comments_url, issue_comment_json
  response_check response, "create comment (#{comments_url})"
  puts "Commented on issue: #{issue["html_url"]}" if options[:notify]
end

def close_issue issue
  issue_url = issue["url"]
  close_issue_json = '{ "state": "closed" }'
  response = http_request :post, issue_url, close_issue_json
  response_check response, "close issue (#{issue_url})"
end

open_issues_url = \
  "https://api.github.com/repos/#{user_repo}/issues?filter=created"
response = http_request :get, open_issues_url
response_check response, "get issues (#{open_issues_url})"

open_issues = JSON.parse response.body

if close
  open_issues.each do |issue|
    comment_body = "Succeeded at #{message}."
    comment_issue issue, comment_body
    close_issue issue
  end
elsif open_issues.any?
  issue = open_issues.first
  comment_issue issue, body, notify: true
else
  title = "#{message} failed for #{@github_username}"
  create_issue user_repo, title, body
end
