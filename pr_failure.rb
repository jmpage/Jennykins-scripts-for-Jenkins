require 'github_api'

ORGANIZATION = "YOUR_ORGANIZATION"
REPO = "YOUR_REPO"

pull = ENV['ghprbPullId']

def github
  @github ||= Github.new do |config|
    config.oauth_token = ENV["GITHUB_API_TOKEN"]
    config.adapter     = :net_http
    config.ssl         = { :verify => false }
  end
end

github.issues.comments.create ORGANIZATION, REPO, pull,
body: "With all that is decent and holy, don't break my test suite!"
