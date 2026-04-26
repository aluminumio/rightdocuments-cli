require "athena-console"
require "oauth-device-flow"
require "rightdocuments-client"
require "./version"

module Right
  CLIENT_ID = ENV["RIGHTDOCUMENTS_CLIENT_ID"]? || "d4803e11ec443f87854a6caec69ab50b"
  BASE_URL  = ENV["RIGHTDOCUMENTS_URL"]? || "https://app.rightdocuments.com"

  # Build a fresh OAuth client. NetrcStore persists tokens at ~/.netrc.
  def self.oauth : OAuth::DeviceFlow::Client
    machine = URI.parse(BASE_URL).hostname || "rightdocuments.com"
    OAuth::DeviceFlow::Client.new(
      base_url:  BASE_URL,
      client_id: CLIENT_ID,
      store:     OAuth::DeviceFlow::NetrcStore.new(machine: machine),
    )
  end

  # Build an SDK config with the current access token. Token refresh is handled
  # by the OAuth client transparently — this just reads the current value.
  def self.sdk_config : RightDocuments::Configuration
    config = RightDocuments::Configuration.default
    uri = URI.parse(BASE_URL)
    config.host         = uri.host.to_s + (uri.port ? ":#{uri.port}" : "")
    config.scheme       = uri.scheme || "https"
    config.access_token = oauth.access_token
    config
  end

  module CLI
    def self.run(argv : Array(String)) : Nil
      app = ACON::Application.new("rightdocuments", VERSION)
      app.add WhoamiCommand.new
      app.add LoginCommand.new
      app.add LogoutCommand.new
      app.add EntitiesCommand.new
      app.add DocumentsCommand.new
      app.add ImportCommand.new
      app.run(ACON::Input::ARGV.new(argv))
    end
  end

  @[ACONA::AsCommand("login", description: "Authenticate via OAuth device flow")]
  class LoginCommand < ACON::Command
    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      Right.oauth.authenticate(scope: "documents:read documents:write")
      output.puts "Logged in."
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "Login failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("logout", description: "Clear stored credentials")]
  class LogoutCommand < ACON::Command
    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      Right.oauth.logout
      output.puts "Logged out."
      ACON::Command::Status::SUCCESS
    end
  end

  @[ACONA::AsCommand("whoami", description: "Show the authenticated user and organization")]
  class WhoamiCommand < ACON::Command
    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      Right.sdk_config
      result = RightDocuments::MeApi.new.api_v1_me_get
      user = result.user
      org  = result.organization
      output.puts "user: #{user.try(&.email) || user.try(&.id)}"
      output.puts "organization: #{org.try(&.name) || org.try(&.id)}"
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "whoami failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("entities", description: "List entities you have access to")]
  class EntitiesCommand < ACON::Command
    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      Right.sdk_config
      api = RightDocuments::EntitiesApi.new
      result = api.api_v1_entities_get
      (result.entities || [] of typeof(result.entities.not_nil!.first)).each do |entity|
        output.puts "#{entity.id}\t#{entity.name}"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "entities failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("documents", description: "List documents for an entity")]
  class DocumentsCommand < ACON::Command
    protected def configure : Nil
      self.argument("entity_id", :required, "entity ID to list documents under")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      Right.sdk_config
      entity_id = input.argument("entity_id").to_s
      api = RightDocuments::DocumentsApi.new
      result = api.api_v1_entities_entity_id_documents_get(entity_id)
      output.puts result.to_pretty_json
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "documents failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("import", description: "Import a PDF as an executed document")]
  class ImportCommand < ACON::Command
    protected def configure : Nil
      self
        .argument("path", :required, "path to the PDF file")
        .option("entity", value_mode: ACON::Input::Option::Value[:required], description: "entity ID to import under")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      path = input.argument("path").to_s
      entity_id = input.option("entity").to_s

      if entity_id.empty?
        output.puts "error: --entity ENTITY_ID is required"
        return ACON::Command::Status::FAILURE
      end
      unless File.exists?(path)
        output.puts "error: file not found: #{path}"
        return ACON::Command::Status::FAILURE
      end

      # The swagger doesn't yet describe the multipart body for import, so the
      # SDK's import method takes only entity_id. Drop to direct HTTP until
      # the swagger is fleshed out.
      uri = URI.parse("#{Right::BASE_URL}/api/v1/entities/#{URI.encode_path(entity_id)}/documents/import")
      io = IO::Memory.new
      builder = HTTP::FormData::Builder.new(io)
      File.open(path) do |file|
        builder.file("file", file, HTTP::FormData::FileMetadata.new(filename: File.basename(path)))
      end
      builder.finish
      headers = HTTP::Headers{
        "Authorization" => "Bearer #{Right.oauth.access_token}",
        "Content-Type"  => builder.content_type,
      }
      response = HTTP::Client.post(uri, headers: headers, body: io.to_s)

      if response.status.success?
        output.puts response.body
        ACON::Command::Status::SUCCESS
      else
        output.puts "import failed: HTTP #{response.status.code} — #{response.body}"
        ACON::Command::Status::FAILURE
      end
    rescue ex
      output.puts "import failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end
end
