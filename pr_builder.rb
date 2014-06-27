require 'faraday'
require 'github_api'
require 'yaml'
require 'rally_api'

LOLCOMMITS_PATH = "/animated_gifs"
LOLCOMMITS_URL  = "http://www.lolcommits.com"
ORGANIZATION = "YOUR_ORGANIZATION"
REPO = "YOUR_REPO"

def github
  @github ||= Github.new do |config|
    config.oauth_token = ENV["GITHUB_API_TOKEN"]
    config.adapter     = :net_http
    config.ssl         = { :verify => false }
  end
end

def animation_url(pull_number)
  previous_pull_commits = []
  begin
    previous_pull_commits = YAML::load_file "/tmp/#{pull_number}_commits.yml"
  rescue Errno::ENOENT
    puts "Pull Request has no previous commits."
    previous_pull_commits = []
  end

  puts "Pull number #{pull_number}"
  commits = github.pull_requests.commits(ORGANIZATION, REPO, pull_number)
  commit_shas = []
  commits.each do |commit|
    commit_shas << commit.sha[0..10]
  end

  commit_shas = commit_shas - previous_pull_commits
  puts commit_shas

  File.open("/tmp/#{pull_number}_commits.yml", "w") do |file|
    file.write commit_shas.to_yaml
  end

  get_animation_url(commit_shas)
end

def lolcommits
  @lolcommits ||= Faraday.new(:url => LOLCOMMITS_URL) do |f|
    f.request  :url_encoded
    f.adapter  Faraday.default_adapter
  end
end

def get_animation_url(shas)
  unless shas.empty?
    response = lolcommits.post LOLCOMMITS_PATH, :animated_gif => { :shas => shas.join(',') }
    puts response.body
    JSON.parse(response.body).fetch("image").fetch("url") if response.status == 200
  end
end

def url_for_rally(project_id, type, object_id)
  "https://rally1.rallydev.com/#/#{project_id}/detail/#{type}/#{object_id}"
end

def generate_markdown_link(text, url)
  "[#{text}](#{url})"
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

# type should be defect or userstory
def query_rally(type, query_string, fetch)
  type = "hierarchicalrequirement" if type == "userstory"

  test_query = RallyAPI::RallyQuery.new()
  test_query.type = type
  test_query.query_string = query_string
  test_query.fetch = fetch

  rally.find(test_query)
end

## Retrieves string replacements for given userstory/defect ids
# type - "userstory" or "defect"
# ids - array of userstory or defect ids, ex: ["US1001", "US1002"]
def string_replacements_for_ids(type, ids)
  ids = ids.uniq
  query_string = ids.map { |id| "(FormattedID = \"#{id}\")" }.join(' OR ')
  query_string = "(#{query_string})" if ids.count > 1

  replacements = {}

  puts "Querying Rally for artifact info..."
  results = query_rally(type, query_string, "FormattedID,ObjectID,Project")
  puts "done."
  results.each do |result|
    if ids.include?(result.FormattedID)
      link_to_artifact = url_for_rally(result.Project.ObjectID, type, result.ObjectID)
      replacements[result.FormattedID] = generate_markdown_link(result.FormattedID, link_to_artifact)
    end
  end

  replacements
end

def replace_rally_ids_with_links(pr_id)
  body = github.pull_requests.get(ORGANIZATION, REPO, pr_id)["body"]
  userstory_ids = body.scan(/((?<!\[)US\d+)/) || []
  task_ids = body.scan(/((?<!\[)TA\d+)/)
  defect_ids = body.scan(/((?<!\[)DE\d+)/)

  if userstory_ids && !userstory_ids.empty?
    puts "Linkifying User Story IDs..."
    string_replacements_for_ids("userstory", userstory_ids.flatten).each do |text, link|
      puts " - #{text}"
      body = body.gsub(/(?<!\[)#{text}/, link)
    end
  end

  if task_ids && !task_ids.empty?
    puts "Linkifying Task IDs..."
    string_replacements_for_ids("task", task_ids.flatten).each do |text, link|
      puts " - #{text}"
      body = body.gsub(/(?<!\[)#{text}/, link)
    end
  end

  if defect_ids && !defect_ids.empty?
    puts "Linkifying Defect IDs..."
    string_replacements_for_ids("defect", defect_ids.flatten).each do |text, link|
      puts " - #{text}"
      body = body.gsub(/(?<!\[)#{text}/, link)
    end
  end

  github.pull_requests.update(ORGANIZATION, REPO, pr_id, "body" => body)
end

def post_build_started_comment(pull)
  open_pull = github.pull_requests.get ORGANIZATION, REPO, pull

  puts "Attempting to retrieve lolcommits..."
  url = animation_url(open_pull.number)
  puts "done."

  if !url || url.blank?
    face = "It's just too darn bad that you won't show your pretty face!"
  else
    face = "![Where's your pretty face!?](#{url})"
  end

  puts "Posting build started comment..."
  github.issues.comments.create ORGANIZATION, REPO, pull,
  "body" => "Hey y'all, I just started building your pull request! #{face}"
  puts "done."
end

pull = ENV['ghprbPullId']

post_build_started_comment(pull)
replace_rally_ids_with_links(pull)
