require 'json'
require 'httparty'
require 'git'
require 'github_api'
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
  print "Retrieving merged pull request ids..."
  ids = []
  git.log.between(old_ref, new_ref).select { |commit| commit.parents.count > 1 }.each do |commit|
    id = commit.message.scan(/Merge pull request #(\d+) from /).flatten.last
    ids << id if id
  end
  puts "done. Retrieved ids: #{ids.join(', ')}"
  ids
end

def get_resolves(pull_request)
  resolves = pull_request["body"].scan(/[Rr]esolves?:? \[?((?:US|DE|TA)\d+)/) || []
  resolves.flatten.uniq
end

def get_resolved_artifact_ids(pull_ids)
  puts "Retrieving resolved artifact ids..."
  resolves = []
  pull_ids.each do |pull_id|
    print "Retreiving resolved artifact ids for ##{pull_id}..."
    pull_request = github.pull_requests.get(ENV['GITHUB_ORGANIZATION'], ENV['GITHUB_REPOSITORY'], pull_id)
    resolves += get_resolves(pull_request)
    puts "done"
  end
  puts "done."
  resolves.uniq
end

def move_artifacts_to_completed(ids)
  puts "Moving resolved artifacts to Completed ScheduleState..."
  ids.each do |id|
    if (id =~ /^DE/) == 0
      type = "defect"
    elsif (id =~ /^US/) == 0
      type = "hierarchicalrequirement"
    elsif (id =~ /^TA/) == 0
      type = "task"
    else
      puts "Unable to determine type of #{id}, skipping."
      next
    end

    begin
      puts "Reading #{id}..."
      artifact = rally.read(type, "FormattedID|#{id}")
      schedule_state = type == "task" ? artifact.State : artifact.ScheduleState
      is_ready = artifact.Ready
      puts "done"

      if schedule_state == "In-Progress" && is_ready
        print "Artifact #{id} is In-Progress and Ready. Changing ScheduleState to Completed..."
        fields = {}
        fields[type == "task" ? "State" : "ScheduleState"] = "Completed"
        fields["Ready"] = false
        artifact.update(fields)
        puts "done"
      else
        puts "Artifact #{id} is not In-Progress (#{schedule_state}) and Ready (#{is_ready ? '' : 'not '}Ready). Skipping."
      end
    rescue StandardError => e
      puts "error"
      puts "Received an exception while trying to retrieve or update #{id}:"
      puts e
    end
  end
end

old_qa_ref = ENV['CURRENT_QA_COMMIT']
qa_deploy_json = HTTParty.get("https://#{ENV['QA_DOMAIN']}/deploy.json", :verify => false).body
qa_ref         = JSON.parse(qa_deploy_json)['ref'] rescue nil

pull_ids = get_pull_ids(old_qa_ref, qa_ref)
resolved_artifact_ids = get_resolved_artifact_ids(pull_ids)
move_artifacts_to_completed(resolved_artifact_ids)
