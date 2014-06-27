require 'github_api'
require 'rally_api'

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

def rally
  return @rally if @rally

  rally_config = {
    :base_url  => "https://rally1.rallydev.com/slm",
    :username  => ENV["RALLY_USERNAME"],
    :password  => ENV["RALLY_PASSWORD"],
    :workspace => ENV["RALLY_WORKSPACE"],
    :project   => ENV["RALLY_PROJECT"],
    :version   => "v2.0"
  }

  @rally = RallyAPI::RallyRestJson.new(rally_config)
end

def post_comment_on_stories_if_unique(comment_to_post, ids)
  # FYI, this is really inefficient, but I was having trouble figuring out how to
  # do a bulk query of Rally's API for all comments, so I am going with this for
  # now.
  ids.each do |id|
    if (id =~ /^DE/) == 0
      type = "defect"
    elsif (id =~ /^US/) == 0
      type = "hierarchicalrequirement"
    elsif (id =~ /^TA/) == 0
      type = "task"
    else
      next
    end

    puts "Checking #{id} to see if it already has a comment for this pull request..."
    artifact = rally.read(type, "FormattedID|#{id}")
    artifact.Discussion.each do |comment| # called ConversationPosts in Rally
      if comment.Text == comment_to_post
        puts "matching comment found, skipping #{id}"
        break
      end
    end || next

    new_comment = {
      "Artifact" => "/#{type}/#{artifact.ObjectID}",
      "Text" => comment_to_post
    }
    rally.create("conversationpost", new_comment)
    puts "Comment, \"#{comment_to_post}\", posted to #{id}"
  end
end

puts "Posting comment on Github..."
github.issues.comments.create ORGANIZATION, REPO, pull,
    body: "Tests passed y'all! Congrats!"

pull_request = github.pull_requests.get(ORGANIZATION, REPO, pull)
pr_url = pull_request["html_url"]
pr_body = pull_request["body"]
pr_number = pull_request["number"]

resolves = pr_body.scan(/[Rr]esolves?:? \[?((?:US|DE|TA)\d+)/) || []
resolves = resolves.flatten.uniq

impacts = pr_body.scan(/[Ii]mpacts?:? \[?((?:US|DE|TA)\d+)/) || []
impacts = impacts.flatten.uniq

puts "Posting resolves comments..." unless resolves.empty?
post_comment_on_stories_if_unique("Resolved by <a href=\"#{pr_url}\">##{pr_number}</a>.", resolves)
puts "Posting impacts comments..." unless impacts.empty?
post_comment_on_stories_if_unique("Impacted by <a href=\"#{pr_url}\">##{pr_number}</a>.", impacts)
