require "athena-console"
require "oauth-device-flow"
require "rightdocuments-client"
require "./version"

module RightDocuments
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

  # If `body` is a 422 validation response with errors on entity_type,
  # formation_state, or status, returns a multi-line hint listing the
  # validation messages and the current catalog values. Returns nil
  # otherwise (so the caller can fall back to its default error output).
  ENUM_FIELDS = {"entity_type", "formation_state", "status"}

  def self.enum_error_hint(body : String) : String?
    parsed = JSON.parse(body) rescue nil
    return nil unless parsed
    errors = parsed["errors"]?.try(&.as_h?)
    return nil unless errors
    return nil unless errors.keys.any? { |k| ENUM_FIELDS.includes?(k.to_s) }

    sdk_config
    catalog = RightDocuments::CatalogApi.new.api_v1_catalog_get rescue nil

    String.build do |io|
      io << "\nTip: at least one of --type/--state/--status was rejected by the server.\n"
      if catalog
        io << "Valid values (also via `rightdocuments catalog`):\n"
        io << "  --type:   #{(catalog.entity_types || [] of String).join(", ")}\n"
        io << "  --state:  #{(catalog.formation_states || [] of String).join(", ")}\n"
        io << "  --status: #{(catalog.entity_statuses || [] of String).join(", ")}"
      else
        io << "Run `rightdocuments catalog` to see valid values."
      end
    end
  end

  # Mixin for data-returning commands. Adds `--json/-j` and exposes `json?(input)`.
  module JSONOption
    macro included
      def self.add_json_option(cmd)
        cmd.option("json", "j", ACON::Input::Option::Value[:none], "Emit JSON instead of human-readable text")
      end
    end

    protected def json?(input : ACON::Input::Interface) : Bool
      input.option("json", Bool)
    end
  end

  module CLI
    def self.run(argv : Array(String)) : Nil
      app = ACON::Application.new("rightdocuments", CLI_VERSION)
      app.add WhoamiCommand.new
      app.add LoginCommand.new
      app.add LogoutCommand.new
      app.add EntitiesCommand.new
      app.add EntitiesCreateCommand.new
      app.add EntitiesUpdateCommand.new
      app.add EntitiesInfoCommand.new
      app.add TemplatesCommand.new
      app.add TemplatesCreateCommand.new
      app.add TemplatesInfoCommand.new
      app.add DocumentsCommand.new
      app.add DocumentsCreateCommand.new
      app.add DocumentsDeleteCommand.new
      app.add DocumentsUpdateCommand.new
      app.add ImportCommand.new
      app.add CatalogCommand.new
      app.add SkillsCommand.new
      app.run(ACON::Input::ARGV.new(argv))
    end
  end

  @[ACONA::AsCommand("skills", description: "Print the agent/LLM usage guide for this CLI")]
  class SkillsCommand < ACON::Command
    SKILL = {{ read_file "#{__DIR__}/skill.md" }}

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      output.print SKILL
      ACON::Command::Status::SUCCESS
    end
  end

  @[ACONA::AsCommand("login", description: "Authenticate via OAuth device flow")]
  class LoginCommand < ACON::Command
    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      RightDocuments.oauth.authenticate(scope: "documents:read documents:write")
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
      RightDocuments.oauth.logout
      output.puts "Logged out."
      ACON::Command::Status::SUCCESS
    end
  end

  @[ACONA::AsCommand("whoami", description: "Show the authenticated user and organization")]
  class WhoamiCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      WhoamiCommand.add_json_option(self)
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      RightDocuments.sdk_config
      result = RightDocuments::MeApi.new.api_v1_me_get
      if json?(input)
        output.puts result.to_pretty_json
      else
        user = result.user
        org  = result.organization
        output.puts "user: #{user.try(&.email) || user.try(&.id)}"
        output.puts "organization: #{org.try(&.name) || org.try(&.id)}"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "whoami failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("entities:list|entities", description: "List entities")]
  class EntitiesCommand < ACON::Command
    include JSONOption

    TYPE_SHORT = {
      "C-Corporation" => "C-Corp", "S-Corporation" => "S-Corp",
      "Limited Liability Company" => "LLC", "General Partnership" => "GP",
      "Limited Partnership" => "LP", "Limited Liability Partnership" => "LLP",
    }

    protected def configure : Nil
      EntitiesCommand.add_json_option(self)
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      uri = URI.parse("#{RightDocuments::BASE_URL}/api/v1/entities")
      headers = HTTP::Headers{"Authorization" => "Bearer #{RightDocuments.oauth.access_token}"}
      response = HTTP::Client.get(uri, headers: headers)
      unless response.status.success?
        output.puts "entities failed: HTTP #{response.status.code}"
        return ACON::Command::Status::FAILURE
      end

      if json?(input)
        output.puts response.body
        return ACON::Command::Status::SUCCESS
      end

      parsed = JSON.parse(response.body)
      entities = parsed["entities"]?.try(&.as_a?) || [] of JSON::Any

      # Table header
      output.puts ""
      output.puts String.build { |s|
        s << "  "
        s << "Name".ljust(36).colorize(:white).mode(:bold)
        s << "Type".ljust(8).colorize(:white).mode(:bold)
        s << "State".ljust(6).colorize(:white).mode(:bold)
        s << "Status".ljust(14).colorize(:white).mode(:bold)
        s << "Incorporated".colorize(:white).mode(:bold)
      }
      output.puts "  #{"─" * 80}"

      entities.sort_by { |e| e["name"]?.try(&.as_s?) || "" }.each do |entity|
        name = entity["name"]?.try(&.as_s?) || "?"
        etype = entity["entity_type"]?.try(&.as_s?) || ""
        short_type = TYPE_SHORT[etype]? || etype[0..5]
        state = entity["state"]?.try(&.as_s?) || ""
        short_state = state == "California" ? "CA" : state == "Delaware" ? "DE" : state[0..1]
        status = entity["status"]?.try(&.as_s?) || ""
        fdate = entity["formation_date"]?.try(&.as_s?)

        date_str = if fdate && !fdate.empty?
                     begin
                       t = Time.parse_utc(fdate, "%Y-%m-%d")
                       t.to_s("%b %Y")
                     rescue
                       fdate
                     end
                   else
                     "—"
                   end

        output.puts String.build { |s|
          s << "  "
          s << name.ljust(36)
          s << short_type.ljust(8).colorize(:cyan)
          s << short_state.ljust(6)
          s << status.ljust(14).colorize(
            status == "Operating" ? :green : status.includes?("Dissolution") ? :red : status == "Unformed" ? :dark_gray : :yellow
          )
          s << date_str
        }
      end

      output.puts ""
      output.puts "  #{entities.size} entities"
      output.puts ""

      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "entities failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("entities:info", description: "Show a single entity by ID")]
  class EntitiesInfoCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      EntitiesInfoCommand.add_json_option(self)
      self.argument("entity_id", :required, "entity ID to look up")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      RightDocuments.sdk_config
      result = RightDocuments::EntitiesApi.new.api_v1_entities_id_get(input.argument("entity_id").to_s)
      if json?(input)
        output.puts result.to_pretty_json
      else
        e = result.entity
        if e
          output.puts "id: #{e.id}"
          output.puts "name: #{e.name}"
          output.puts "type: #{e.entity_type}"
          output.puts "state: #{e.state}"
          output.puts "status: #{e.status}"
          show = ->(label : String, value : String?) {
            output.puts "#{label}: #{value}" if value && !value.empty?
          }
          show.call("formation_date", e.formation_date)
          show.call("ein", e.ein)
          show.call("duns", e.duns)
          show.call("file_number", e.file_number)
          show.call("fiscal_year_end", e.fiscal_year_end_month_day)
          if shares = e.shares_authorized
            output.puts "shares_authorized: #{shares}"
          end
          show.call("address", e.address)
          show.call("county", e.county)
          show.call("phone", e.phone)
          show.call("website", e.website_url)
          show.call("registered_agent_name", e.registered_agent_name)
          show.call("registered_agent_address", e.registered_agent_address)
          show.call("incorporator_name", e.incorporator_name)
          show.call("incorporator_address", e.incorporator_address)
          show.call("incorporator_resigned_on", e.incorporator_resigned_on)
          {1, 2, 3}.each do |i|
            name  = case i; when 1; e.officer_1_name; when 2; e.officer_2_name; else e.officer_3_name; end
            title = case i; when 1; e.officer_1_title; when 2; e.officer_2_title; else e.officer_3_title; end
            email = case i; when 1; e.officer_1_email; when 2; e.officer_2_email; else e.officer_3_email; end
            next unless (name && !name.empty?) || (title && !title.empty?) || (email && !email.empty?)
            parts = [] of String
            parts << name.to_s if name && !name.empty?
            parts << "(#{title})" if title && !title.empty?
            parts << "<#{email}>" if email && !email.empty?
            output.puts "officer_#{i}: #{parts.join(" ")}"
          end
          show.call("created_at", e.created_at)
          show.call("updated_at", e.updated_at)
        else
          output.puts result.to_pretty_json
        end
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "entities:info failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("catalog", description: "List entity types, formation states, statuses, and checklists")]
  class CatalogCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      CatalogCommand.add_json_option(self)
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      uri = URI.parse("#{RightDocuments::BASE_URL}/api/v1/catalog")
      response = HTTP::Client.get(uri)
      unless response.status.success?
        output.puts "catalog failed: HTTP #{response.status.code}"
        return ACON::Command::Status::FAILURE
      end

      if json?(input)
        output.puts response.body
        return ACON::Command::Status::SUCCESS
      end

      catalog = JSON.parse(response.body)
      output.puts "entity_types:     #{catalog["entity_types"]?.try(&.as_a.join(", "))}"
      output.puts "formation_states: #{catalog["formation_states"]?.try(&.as_a.join(", "))}"
      output.puts "entity_statuses:  #{catalog["entity_statuses"]?.try(&.as_a.join(", "))}"

      if reqs = catalog["formation_requirements"]?.try(&.as_h?)
        output.puts ""
        reqs.each do |key, steps|
          output.puts "--- #{key} ---"
          steps.as_a.each do |step|
            tag  = step["required_tag"]?.try(&.as_s) || "?"
            name = step["name"]?.try(&.as_s) || "?"
            desc = step["description"]?.try(&.as_s) || ""
            output.puts "  [#{tag}] #{name}"
            output.puts "    #{desc}" unless desc.empty?
          end
          output.puts ""
        end
      end

      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "catalog failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("entities:create", description: "Create an entity in the authenticated organization")]
  class EntitiesCreateCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      EntitiesCreateCommand.add_json_option(self)
      self
        .option("name", nil, ACON::Input::Option::Value[:required], "Legal name of the entity")
        .option("type", nil, ACON::Input::Option::Value[:required], "Entity type (e.g. LLC, Corp)")
        .option("state", nil, ACON::Input::Option::Value[:required], "Formation state (e.g. DE, CA)")
        .option("formation-date", nil, ACON::Input::Option::Value[:required], "Formation date (YYYY-MM-DD)")
        .option("ein", nil, ACON::Input::Option::Value[:required], "Employer Identification Number")
        .option("address", nil, ACON::Input::Option::Value[:required], "Mailing address")
        .option("phone", nil, ACON::Input::Option::Value[:required], "Phone number")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      name  = input.option("name").to_s
      type  = input.option("type").to_s
      state = input.option("state").to_s

      if name.empty? || type.empty? || state.empty?
        output.puts "error: --name, --type, and --state are required"
        return ACON::Command::Status::FAILURE
      end

      formation_date = nil
      if raw = input.option("formation-date").to_s.presence
        begin
          formation_date = Time.parse_utc(raw, "%Y-%m-%d")
        rescue Time::Format::Error
          output.puts "error: --formation-date must be YYYY-MM-DD (got #{raw.inspect})"
          return ACON::Command::Status::FAILURE
        end
      end

      # Swagger doesn't describe the 201 response, so the SDK returns nil.
      # Build the body via the typed request model, post with HTTP::Client.
      entity = RightDocuments::ApiV1EntitiesPostRequestEntity.new(
        name: name,
        entity_type: type,
        formation_state: state,
        status: nil,
        formation_date: formation_date,
        ein: input.option("ein").to_s.presence,
        address: input.option("address").to_s.presence,
        phone: input.option("phone").to_s.presence,
      )
      body = RightDocuments::ApiV1EntitiesPostRequest.new(entity: entity).to_json

      uri = URI.parse("#{RightDocuments::BASE_URL}/api/v1/entities")
      headers = HTTP::Headers{
        "Authorization" => "Bearer #{RightDocuments.oauth.access_token}",
        "Content-Type"  => "application/json",
      }
      response = HTTP::Client.post(uri, headers: headers, body: body)
      unless response.status.success?
        output.puts "entities:create failed: HTTP #{response.status.code} — #{response.body}"
        if hint = RightDocuments.enum_error_hint(response.body)
          output.puts hint
        end
        return ACON::Command::Status::FAILURE
      end

      if json?(input)
        output.puts response.body
      else
        parsed = JSON.parse(response.body) rescue nil
        e = parsed.try(&.["entity"]?) || parsed
        if e && (id = e["id"]?)
          output.puts "#{id}\t#{e["name"]? || name}"
        else
          output.puts response.body
        end
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "entities:create failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("entities:update", description: "Update an entity's metadata")]
  class EntitiesUpdateCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      EntitiesUpdateCommand.add_json_option(self)
      self
        .argument("entity_id", :required, "entity ID to update")
        .option("name", nil, ACON::Input::Option::Value[:required], "legal name")
        .option("status", nil, ACON::Input::Option::Value[:required], "entity status")
        .option("ein", nil, ACON::Input::Option::Value[:required], "EIN")
        .option("address", nil, ACON::Input::Option::Value[:required], "principal address")
        .option("phone", nil, ACON::Input::Option::Value[:required], "phone number")
        .option("formation-date", nil, ACON::Input::Option::Value[:required], "formation date (YYYY-MM-DD)")
        .option("notes", nil, ACON::Input::Option::Value[:required], "markdown notes about the entity")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("entity_id").to_s
      entity = {} of String => String | Nil
      %w[name status ein address phone notes].each do |f|
        if v = input.option(f).to_s.presence
          entity[f] = v
        end
      end
      if v = input.option("formation-date").to_s.presence
        entity["formation_date"] = v
      end
      if entity.empty?
        output.puts "error: provide at least one field to update (--name, --status, --ein, etc.)"
        return ACON::Command::Status::FAILURE
      end

      uri = URI.parse("#{RightDocuments::BASE_URL}/api/v1/entities/#{URI.encode_path(id)}")
      headers = HTTP::Headers{
        "Authorization" => "Bearer #{RightDocuments.oauth.access_token}",
        "Content-Type"  => "application/json",
      }
      body = { "entity" => entity }.to_json
      response = HTTP::Client.patch(uri, headers: headers, body: body)
      unless response.status.success?
        output.puts "entities:update failed: HTTP #{response.status.code} — #{response.body}"
        return ACON::Command::Status::FAILURE
      end

      if json?(input)
        output.puts response.body
      else
        parsed = JSON.parse(response.body).dig?("entity")
        if parsed
          output.puts "#{parsed["id"]?}\t#{parsed["name"]?}"
        else
          output.puts response.body
        end
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "entities:update failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("templates:list|templates", description: "List available templates")]
  class TemplatesCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      TemplatesCommand.add_json_option(self)
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      uri = URI.parse("#{RightDocuments::BASE_URL}/api/v1/templates")
      headers = HTTP::Headers{"Authorization" => "Bearer #{RightDocuments.oauth.access_token}"}
      response = HTTP::Client.get(uri, headers: headers)
      unless response.status.success?
        output.puts "templates failed: HTTP #{response.status.code}"
        return ACON::Command::Status::FAILURE
      end

      if json?(input)
        output.puts response.body
      else
        parsed = JSON.parse(response.body)
        (parsed["templates"]?.try(&.as_a?) || [] of JSON::Any).each do |t|
          tags = t["tags"]?.try(&.as_a?.try(&.join(", "))) || ""
          output.puts "#{t["id"]?}\t#{t["name"]?}"
          output.puts "  tags: #{tags}" unless tags.empty?
        end
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "templates failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("templates:info", description: "Show template details and required fields")]
  class TemplatesInfoCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      TemplatesInfoCommand.add_json_option(self)
      self.argument("template_id", :required, "template ID to inspect")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("template_id").to_s
      uri = URI.parse("#{RightDocuments::BASE_URL}/api/v1/templates/#{URI.encode_path(id)}")
      headers = HTTP::Headers{"Authorization" => "Bearer #{RightDocuments.oauth.access_token}"}
      response = HTTP::Client.get(uri, headers: headers)
      unless response.status.success?
        output.puts "templates:info failed: HTTP #{response.status.code}"
        return ACON::Command::Status::FAILURE
      end

      if json?(input)
        output.puts response.body
        return ACON::Command::Status::SUCCESS
      end

      t = JSON.parse(response.body).dig?("template")
      return ACON::Command::Status::FAILURE unless t

      output.puts "#{t["name"]?}"
      output.puts "tags: #{t["tags"]?.try(&.as_a?.try(&.join(", ")))}"
      output.puts ""
      output.puts "Fields:"
      (t["fields"]?.try(&.as_a?) || [] of JSON::Any).each do |f|
        entity = f["entity_field"]?.try(&.as_bool?) ? " (auto)" : ""
        req = f["required"]?.try(&.as_bool?) ? "*" : " "
        default = f["default"]?.try(&.as_s?)
        line = "  #{req} #{f["name"]?} — #{f["label"]?} (#{f["type"]?})#{entity}"
        line += " [default: #{default}]" if default
        output.puts line
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "templates:info failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("templates:create", description: "Create a template from a markdown file")]
  class TemplatesCreateCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      TemplatesCreateCommand.add_json_option(self)
      self
        .option("name", nil, ACON::Input::Option::Value[:required], "Template name")
        .option("content", nil, ACON::Input::Option::Value[:required], "Path to markdown file with template content")
        .option("description", nil, ACON::Input::Option::Value[:required], "Description of when to use this template")
        .option("tags", nil, ACON::Input::Option::Value[:required], "Comma-separated tags")
        .option("public", nil, ACON::Input::Option::Value[:none], "Make template visible to other organizations")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      name = input.option("name").to_s
      content_path = input.option("content").to_s

      if name.empty? || content_path.empty?
        output.puts "error: --name and --content are required"
        return ACON::Command::Status::FAILURE
      end

      unless File.exists?(content_path)
        output.puts "error: file not found: #{content_path}"
        return ACON::Command::Status::FAILURE
      end

      content = File.read(content_path)

      template = {} of String => String | Bool
      template["name"] = name
      template["content"] = content
      if desc = input.option("description").to_s.presence
        template["description"] = desc
      end
      if tags = input.option("tags").to_s.presence
        template["tag_list"] = tags
      end
      if input.option("public", Bool)
        template["public"] = true
      end

      uri = URI.parse("#{RightDocuments::BASE_URL}/api/v1/templates")
      headers = HTTP::Headers{
        "Authorization" => "Bearer #{RightDocuments.oauth.access_token}",
        "Content-Type"  => "application/json",
      }
      body = { "template" => template }.to_json
      response = HTTP::Client.post(uri, headers: headers, body: body)
      unless response.status.success?
        output.puts "templates:create failed: HTTP #{response.status.code} — #{response.body}"
        return ACON::Command::Status::FAILURE
      end

      if json?(input)
        output.puts response.body
      else
        parsed = JSON.parse(response.body).dig?("template")
        if parsed
          output.puts "#{parsed["id"]?}\t#{parsed["name"]?}"
        else
          output.puts response.body
        end
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "templates:create failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("documents:create", description: "Create a document from a template")]
  class DocumentsCreateCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DocumentsCreateCommand.add_json_option(self)
      self
        .option("template", nil, ACON::Input::Option::Value[:required], "template ID")
        .option("entity", "e", ACON::Input::Option::Value[:required], "entity ID")
        .option("field", "f", ACON::Input::Option::Value[:required] | ACON::Input::Option::Value[:is_array], "field=value pairs")
        .option("execute", nil, ACON::Input::Option::Value[:none], "finalize and execute immediately")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      template_id = input.option("template").to_s
      entity_id = input.option("entity").to_s
      if template_id.empty? || entity_id.empty?
        output.puts "error: --template and --entity are required"
        return ACON::Command::Status::FAILURE
      end

      field_values = {} of String => String
      input.option("field", Array(String)).each do |pair|
        k, _, v = pair.partition("=")
        field_values[k] = v unless k.empty?
      end

      body = {
        "template_id"  => template_id,
        "field_values"  => field_values,
        "execute"      => input.option("execute", Bool),
      }

      uri = URI.parse("#{RightDocuments::BASE_URL}/api/v1/entities/#{URI.encode_path(entity_id)}/documents")
      headers = HTTP::Headers{
        "Authorization" => "Bearer #{RightDocuments.oauth.access_token}",
        "Content-Type"  => "application/json",
      }
      response = HTTP::Client.post(uri, headers: headers, body: body.to_json)
      unless response.status.success?
        output.puts "documents:create failed: HTTP #{response.status.code} — #{response.body}"
        return ACON::Command::Status::FAILURE
      end

      if json?(input)
        output.puts response.body
      else
        doc = JSON.parse(response.body).dig?("document")
        if doc
          output.puts "#{doc["id"]?}\t#{doc["name"]?}\tstatus=#{doc["status"]?}"
          if tags = doc["tags"]?.try(&.as_a?)
            output.puts "tags: #{tags.join(", ")}" unless tags.empty?
          end
        else
          output.puts response.body
        end
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "documents:create failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("documents:list|documents", description: "List documents for an entity")]
  class DocumentsCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DocumentsCommand.add_json_option(self)
      self.argument("entity_id", :required, "entity ID to list documents under")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      entity_id = input.argument("entity_id").to_s
      # Swagger doesn't describe the response schema, so call HTTP directly.
      uri = URI.parse("#{RightDocuments::BASE_URL}/api/v1/entities/#{URI.encode_path(entity_id)}/documents")
      headers = HTTP::Headers{"Authorization" => "Bearer #{RightDocuments.oauth.access_token}"}
      response = HTTP::Client.get(uri, headers: headers)
      unless response.status.success?
        output.puts "documents failed: HTTP #{response.status.code} — #{response.body}"
        return ACON::Command::Status::FAILURE
      end

      if json?(input)
        output.puts response.body
      else
        parsed = JSON.parse(response.body)
        docs = parsed["documents"]?.try(&.as_a?) || [] of JSON::Any
        docs.each do |doc|
          output.puts "#{doc["id"]?}\t#{doc["name"]? || doc["id"]?}"
        end
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "documents failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("documents:delete", description: "Delete a document by ID")]
  class DocumentsDeleteCommand < ACON::Command
    protected def configure : Nil
      self.argument("id", :required, "document ID to delete")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      if id.empty?
        output.puts "error: document ID is required"
        return ACON::Command::Status::FAILURE
      end

      RightDocuments.sdk_config
      _, status, _ = RightDocuments::DocumentsApi.new.api_v1_documents_id_delete_with_http_info(id)
      if status == 204
        output.puts "deleted #{id}"
        ACON::Command::Status::SUCCESS
      else
        output.puts "documents:delete failed: HTTP #{status}"
        ACON::Command::Status::FAILURE
      end
    rescue ex
      output.puts "documents:delete failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("documents:update", description: "Update document metadata (tags, name)")]
  class DocumentsUpdateCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DocumentsUpdateCommand.add_json_option(self)
      self
        .argument("id", :required, "document ID to update")
        .option("tags", "t", ACON::Input::Option::Value[:required], "comma-separated tags")
        .option("name", nil, ACON::Input::Option::Value[:required], "display name")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      body = {} of String => String
      if tags = input.option("tags").to_s.presence
        body["tag_list"] = tags
      end
      if name = input.option("name").to_s.presence
        body["name"] = name
      end
      if body.empty?
        output.puts "error: provide --tags and/or --name"
        return ACON::Command::Status::FAILURE
      end

      uri = URI.parse("#{RightDocuments::BASE_URL}/api/v1/documents/#{URI.encode_path(id)}")
      headers = HTTP::Headers{
        "Authorization" => "Bearer #{RightDocuments.oauth.access_token}",
        "Content-Type"  => "application/json",
      }
      response = HTTP::Client.patch(uri, headers: headers, body: body.to_json)
      unless response.status.success?
        output.puts "documents:update failed: HTTP #{response.status.code} — #{response.body}"
        return ACON::Command::Status::FAILURE
      end

      if json?(input)
        output.puts response.body
      else
        parsed = JSON.parse(response.body).dig?("document")
        if parsed
          output.puts "#{parsed["id"]?}\t#{parsed["name"]?}"
          if tags_arr = parsed["tags"]?.try(&.as_a?)
            output.puts "tags: #{tags_arr.join(", ")}"
          end
        else
          output.puts response.body
        end
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "documents:update failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("import", description: "Import a PDF as an executed document")]
  class ImportCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ImportCommand.add_json_option(self)
      self
        .argument("path", :required, "path to the PDF file")
        .option("entity", "e", ACON::Input::Option::Value[:required], "entity ID to import under")
        .option("tags", "t", ACON::Input::Option::Value[:required], "comma-separated tags to apply")
        .option("name", nil, ACON::Input::Option::Value[:required], "display name for the document")
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
      uri = URI.parse("#{RightDocuments::BASE_URL}/api/v1/entities/#{URI.encode_path(entity_id)}/documents/import")
      io = IO::Memory.new
      builder = HTTP::FormData::Builder.new(io)
      File.open(path) do |file|
        builder.file("file", file, HTTP::FormData::FileMetadata.new(filename: File.basename(path)))
      end
      builder.finish
      headers = HTTP::Headers{
        "Authorization" => "Bearer #{RightDocuments.oauth.access_token}",
        "Content-Type"  => builder.content_type,
      }
      response = HTTP::Client.post(uri, headers: headers, body: io.to_s)

      unless response.status.success?
        output.puts "import failed: HTTP #{response.status.code} — #{response.body}"
        return ACON::Command::Status::FAILURE
      end

      parsed = JSON.parse(response.body).dig?("document") rescue nil
      doc_id = parsed.try(&.["id"]?).try(&.as_s?)

      # Apply tags/name via PATCH if provided
      tags_val = input.option("tags").to_s.presence
      name_val = input.option("name").to_s.presence
      if doc_id && (tags_val || name_val)
        patch_body = {} of String => String
        patch_body["tag_list"] = tags_val.not_nil! if tags_val
        patch_body["name"] = name_val.not_nil! if name_val
        patch_uri = URI.parse("#{RightDocuments::BASE_URL}/api/v1/documents/#{URI.encode_path(doc_id)}")
        patch_headers = HTTP::Headers{
          "Authorization" => "Bearer #{RightDocuments.oauth.access_token}",
          "Content-Type"  => "application/json",
        }
        patch_resp = HTTP::Client.patch(patch_uri, headers: patch_headers, body: patch_body.to_json)
        parsed = JSON.parse(patch_resp.body).dig?("document") rescue parsed if patch_resp.status.success?
      end

      if json?(input)
        output.puts (parsed || JSON.parse(response.body)).to_pretty_json
      else
        output.puts "#{parsed.try(&.["id"]?) || doc_id}\t#{parsed.try(&.["name"]?) || doc_id}"
        if tags_arr = parsed.try(&.["tags"]?).try(&.as_a?)
          output.puts "tags: #{tags_arr.join(", ")}" unless tags_arr.empty?
        end
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "import failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end
end
