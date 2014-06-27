require 'json'
require 'git'
require 'github_api'
require 'httparty'
require 'rally_api'

def git
  @git ||= Git.open('.')
end

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

def get_pull_ids(old_ref, new_ref)
  puts "Retrieving merged pull request ids..."
  ids = []
  git.log.between(old_ref, new_ref).select { |commit| commit.parents.count > 1 }.each do |commit|
    id = commit.message.scan(/Merge pull request #(\d+) from /).flatten.last
    ids << id if id
  end
  puts "ids: #{ids.join(', ')}"
  puts "done"
  ids
end

def get_resolves(pull_request)
  resolves = pull_request["body"].scan(/[Rr]esolves?:? \[?((?:US|DE|TA)\d+)/) || []
  resolves.flatten.uniq
end

def get_impacts(pull_request)
  impacts = pull_request["body"].scan(/[Ii]mpacts?:? \[?((?:US|DE|TA)\d+)/) || []
  impacts.flatten.uniq
end

def url_for_rally(project_id, type, object_id)
  "https://rally1.rallydev.com/#/#{project_id}/detail/#{type}/#{object_id}"
end

def get_line_for(rally_id)
  if (rally_id =~ /^DE/) == 0
    type = "defect"
  elsif (rally_id =~ /^US/) == 0
    type = "hierarchicalrequirement"
  elsif (rally_id =~ /^TA/) == 0
    type = "task"
  else
    return
  end

  begin
    puts "Retrieving Rally artifact #{rally_id}..."
    artifact = rally.read(type, "FormattedID|#{rally_id}")
    url = url_for_rally(artifact.Project.ObjectID, type, artifact.ObjectID)
    name = artifact.Name

    puts "done."
    "<li><a href=\"#{url}\">#{rally_id}</a> - #{name}</li>\\"
  rescue StandardError => e
    puts "Received exception:"
    puts e
    "<li>#{rally_id}</li>"
  end
end

def get_list_for(ids)
  puts "Building list for #{ids}:"
  list = "<ul>\\"
  ids.each do |id|
    list += get_line_for(id)
  end
  list += "</ul>\\"
  puts "done."
  list
end

def get_change_log_for(old_ref, new_ref)
  puts "Getting change log for merge commits between #{old_ref} and #{new_ref}:"
  pull_ids = get_pull_ids(old_ref, new_ref)
  resolves = []
  impacts = []

  pull_ids.each do |pull_id|
    pull_request = github.pull_requests.get('ORG', 'REPO', pull_id)
    resolves += get_resolves(pull_request)
    impacts += get_impacts(pull_request)
  end

  resolves.uniq!
  impacts.uniq!
  impacts -= resolves

  resolves_html = "<h2>Resolved User Stories, Tasks and Defects:</h2>\\"
  resolves_html += get_list_for(resolves)

  impacts_html = "<h2>Impacted User Stories, Tasks and Defects:</h2>\\"
  impacts_html += get_list_for(impacts)

  resolves_html + impacts_html
end

production_deploy_json = HTTParty.get("https://PRODDOMAIN/deploy.json",    :verify => false).body
qa_deploy_json         = HTTParty.get("https://QADOMAIN/deploy.json", :verify => false).body

production_ref = JSON.parse(production_deploy_json)['ref'] rescue nil
qa_ref         = JSON.parse(qa_deploy_json)['ref'] rescue nil
current_ref    = git.revparse('HEAD')

puts "QA REF IS = #{qa_ref}"
puts "CURRENT REF IS = #{current_ref}"
puts "PRODUCTION REF IS = #{production_ref}"

qa_change_log = get_change_log_for(qa_ref, current_ref)
prod_change_log = get_change_log_for(production_ref, qa_ref)

File.open("/tmp/propsfile", "w") do |file|
  file.write "QA_CHANGE_LOG=#{qa_change_log} \n"
  file.write "PROD_CHANGE_LOG=#{prod_change_log} \n"
  file.write "CURRENT_QA_COMMIT=#{qa_ref} \n"
  file.write "COMMIT_TO_DEPLOY=#{current_ref}"
end
