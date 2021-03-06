require 'fileutils'

class CocinaDruidRetriever
  attr_reader :druid

  def initialize(druid)
    @druid = druid
  end

  def self.try_retrieving_unseen_druids(max_to_retrieve: Settings.max_unseen_druids_to_retrieve)
    Druid.unretrieved.limit(max_to_retrieve).find_each { |druid| try_retrieval_and_log_result(druid.druid) }
    nil
  end

  def self.try_retrieval_and_log_result(druid)
    new(druid).try_retrieval_and_log_result
  end

  def try_retrieval_and_log_result
    Rails.logger.info("retrieving #{druid}")
    response = DsaClient.object_show(druid)
    if response.status == 200
      Rails.logger.info("success: 200 OK retrieving #{druid}")
      output_filename = write_cocina_success_to_file(response)
    else
      Rails.logger.warn("failure: #{response.status} #{response.reason_phrase} retrieving #{druid} : #{response.body}")
      output_filename = write_cocina_failure_to_file(response)
    end
    insert_druid_retrieval_attempt(response.status, response.reason_phrase, output_filename)

    response
  rescue StandardError => e
    Rails.logger.error("Unexpected error trying to retrieve #{druid} and log result: #{Util.exception_msg_and_backtrace_str(e)}")
  end

  private

  # if there isn't already a DB entry for the druid, create one, otherwise just return what we already have
  def druid_db_obj
    @druid_db_obj ||= Druid.find_or_create_by!(druid: druid)
  end

  def insert_druid_retrieval_attempt(response_status, response_reason_phrase, output_path)
    DruidRetrievalAttempt.create!(
      druid: druid_db_obj.reload, response_status: response_status, response_reason_phrase: response_reason_phrase, output_path: output_path
    )
  end

  # returns the name of the output file
  def write_cocina_success_to_file(response)
    return unless Settings.cocina_output.success.should_output
    write_druid_response_to_file(Settings.cocina_output.success.location, Util.faraday_response_to_json(response))
  end

  # returns the name of the output file
  def write_cocina_failure_to_file(response)
    return unless Settings.cocina_output.failure.should_output
    write_druid_response_to_file(Settings.cocina_output.failure.location, Util.faraday_response_to_json(response))
  end

  # returns the name of the output file
  def write_druid_response_to_file(output_path, druid_output)
    output_filename = druid_path(output_path)
    ensure_containing_dir(output_filename)
    File.open(output_filename, 'w') do |file|
      file.write(druid_output)
    end
    output_filename
  rescue StandardError => e
    Rails.logger.error("Unexpected error trying to write druid response to file: #{Util.exception_msg_and_backtrace_str(e)}")
  end

  def druid_path(output_path)
    d = DruidTools::Druid.new(druid, output_path) # https://github.com/sul-dlss/druid-tools/#get-attributes-and-paths
    File.join(d.path, "#{current_time_str}.json") # TODO: maybe omit the .json or get clever and lop it off in cases where json couldn't be written, e.g. when JSON writer runs into char it can't handle
  end

  def current_time_str
    DateTime.now.utc.iso8601.to_s
  end

  def ensure_containing_dir(filename)
    basename_len = File.basename(filename).length
    filepath_str = filename[0..-(basename_len + 1)] # add 1 to basename_len because ending at -1 gets the whole string
    FileUtils.mkdir_p(filepath_str) unless FileTest.exist?(filepath_str)
  end
end
