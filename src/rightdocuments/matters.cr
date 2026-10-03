# Clients, matters and matter parties. These endpoints return JSON without a
# full response schema in the swagger, so the commands use direct HTTP (like
# `entities` and `import`) and read the JSON themselves.
module RightDocuments
  # Small JSON-over-HTTP helper for the API. Raises with the server's message on failure.
  module Api
    def self.request(method : String, path : String, body : String? = nil, content_type : String = "application/json") : JSON::Any
      uri = URI.parse("#{BASE_URL}#{path}")
      headers = HTTP::Headers{"Authorization" => "Bearer #{RightDocuments.oauth.access_token}"}
      headers["Content-Type"] = content_type if body
      response = HTTP::Client.exec(method, uri, headers: headers, body: body)
      unless response.status.success?
        message = (JSON.parse(response.body)["message"]?.try(&.as_s?) rescue nil) || response.body
        errors = (JSON.parse(response.body)["errors"]? rescue nil)
        detail = errors ? " #{errors.to_json}" : ""
        raise "HTTP #{response.status.code}: #{message}#{detail}"
      end
      response.body.empty? ? JSON::Any.new(nil) : JSON.parse(response.body)
    end

    def self.get(path : String) : JSON::Any
      request("GET", path)
    end

    def self.post(path : String, payload) : JSON::Any
      request("POST", path, payload.to_json)
    end

    def self.patch(path : String, payload) : JSON::Any
      request("PATCH", path, payload.to_json)
    end

    def self.delete(path : String) : JSON::Any
      request("DELETE", path)
    end

    def self.path_segment(value : String) : String
      URI.encode_path_segment(value)
    end
  end

  # Text helpers shared by the matter commands.
  module MatterText
    def self.s(value : JSON::Any?) : String
      value.try(&.as_s?) || ""
    end

    def self.or_dash(value : JSON::Any?) : String
      text = s(value)
      text.empty? ? "—" : text
    end

    LABELS = {"pre_litigation" => "Pre-litigation"}

    def self.humanize(value : String) : String
      return "—" if value.empty?
      LABELS[value]? || value.gsub('_', ' ').capitalize
    end
  end

  @[ACONA::AsCommand("clients", description: "List clients with their numbers")]
  class ClientsCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ClientsCommand.add_json_option(self)
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      result = Api.get("/api/v1/clients")
      if json?(input)
        output.puts result.to_pretty_json
        return ACON::Command::Status::SUCCESS
      end

      clients = result["clients"]?.try(&.as_a?) || [] of JSON::Any
      output.puts ""
      output.puts "  #{"No.".ljust(6)}#{"Name".ljust(36)}#{"Type".ljust(12)}Status"
      output.puts "  #{"─" * 64}"
      clients.each do |client|
        output.puts "  #{MatterText.s(client["number"]?).ljust(6)}#{MatterText.s(client["name"]?).ljust(36)}" \
                    "#{MatterText.s(client["client_type"]?).ljust(12)}#{MatterText.s(client["status"]?)}"
      end
      output.puts ""
      output.puts "  #{clients.size} clients"
      output.puts ""
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "clients failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("matters", description: "List matters (open by default)")]
  class MattersCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      MattersCommand.add_json_option(self)
      self
        .option("status", "s", ACON::Input::Option::Value[:required], "open or closed (default: open)")
        .option("client", "c", ACON::Input::Option::Value[:required], "client number or ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      params = URI::Params.new
      params["status"] = input.option("status").to_s.presence || "open"
      if client = input.option("client").to_s.presence
        params["client"] = client
      end
      result = Api.get("/api/v1/matters?#{params}")
      if json?(input)
        output.puts result.to_pretty_json
        return ACON::Command::Status::SUCCESS
      end

      matters = result["matters"]?.try(&.as_a?) || [] of JSON::Any
      output.puts ""
      output.puts "  #{"No.".ljust(10)}#{"Matter".ljust(40)}#{"Client".ljust(22)}#{"Type".ljust(16)}Status"
      output.puts "  #{"─" * 96}"
      matters.each do |matter|
        output.puts "  #{MatterText.s(matter["number"]?).ljust(10)}#{MatterText.s(matter["name"]?)[0, 38].ljust(40)}" \
                    "#{MatterText.s(matter.dig?("client", "name"))[0, 20].ljust(22)}" \
                    "#{MatterText.humanize(MatterText.s(matter["matter_type"]?)).ljust(16)}#{MatterText.s(matter["status"]?)}"
      end
      output.puts ""
      output.puts "  #{matters.size} matters"
      output.puts ""
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "matters failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  # Prints one matter with its parties.
  def self.print_matter(output : ACON::Output::Interface, matter : JSON::Any) : Nil
    output.puts "number: #{MatterText.s(matter["number"]?)}"
    output.puts "name: #{MatterText.s(matter["name"]?)}"
    output.puts "client: #{MatterText.s(matter.dig?("client", "number"))} #{MatterText.s(matter.dig?("client", "name"))}"
    output.puts "type: #{MatterText.humanize(MatterText.s(matter["matter_type"]?))}"
    output.puts "our role: #{MatterText.humanize(MatterText.s(matter["our_role"]?))}"
    output.puts "status: #{MatterText.s(matter["status"]?)}"
    output.puts "opened: #{MatterText.or_dash(matter["opened_on"]?)}"
    output.puts "closed: #{MatterText.or_dash(matter["closed_on"]?)}" if matter["closed_on"]?.try(&.as_s?)
    output.puts "id: #{MatterText.s(matter["id"]?)}"
    if description = matter["description"]?.try(&.as_s?)
      output.puts "description: #{description}" unless description.empty?
    end
    if count = matter["document_count"]?.try(&.as_i?)
      output.puts "documents: #{count}"
    end
    parties = matter["parties"]?.try(&.as_a?) || [] of JSON::Any
    output.puts "parties:#{parties.empty? ? " none" : ""}"
    parties.each { |party| output.puts "  - #{MatterText.s(party["name"]?)} (#{MatterText.humanize(MatterText.s(party["role"]?))})" }
  end

  @[ACONA::AsCommand("matters:info", description: "Show a matter by number (e.g. 0004-001) or ID")]
  class MattersInfoCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      MattersInfoCommand.add_json_option(self)
      self.argument("matter", :required, "matter number (0004-001 or 4-1) or ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      result = Api.get("/api/v1/matters/#{Api.path_segment(input.argument("matter").to_s)}")
      if json?(input)
        output.puts result.to_pretty_json
      else
        RightDocuments.print_matter(output, result["matter"])
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "matters:info failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("matters:create", description: "Open a matter for a client (number is assigned on creation)")]
  class MattersCreateCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      MattersCreateCommand.add_json_option(self)
      self
        .option("client", "c", ACON::Input::Option::Value[:required], "client number or ID (see `rightdocuments clients`)")
        .option("name", nil, ACON::Input::Option::Value[:required], "matter name, e.g. \"Malone v. Olde Towne Tavern\"")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      client = input.option("client").to_s
      name = input.option("name").to_s
      if client.empty? || name.empty?
        output.puts "error: --client and --name are required"
        return ACON::Command::Status::FAILURE
      end

      result = Api.post("/api/v1/matters", {matter: {client: client, name: name}})
      if json?(input)
        output.puts result.to_pretty_json
      else
        matter = result["matter"]
        output.puts "#{MatterText.s(matter["number"]?)}\t#{MatterText.s(matter["name"]?)}"
        output.puts "Set the type, role and other settings with `rightdocuments matters:update #{MatterText.s(matter["number"]?)}`."
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "matters:create failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("matters:update", description: "Change a matter's settings")]
  class MattersUpdateCommand < ACON::Command
    include JSONOption

    FIELDS = {
      "name"        => "name",
      "type"        => "matter_type",
      "role"        => "our_role",
      "status"      => "status",
      "opened"      => "opened_on",
      "closed"      => "closed_on",
      "description" => "description",
      "outcome"     => "outcome",
    }

    protected def configure : Nil
      MattersUpdateCommand.add_json_option(self)
      self
        .argument("matter", :required, "matter number or ID")
        .option("name", nil, ACON::Input::Option::Value[:required], "matter name")
        .option("type", nil, ACON::Input::Option::Value[:required], "advisory, pre_litigation or litigation")
        .option("role", nil, ACON::Input::Option::Value[:required], "plaintiff, defendant, claimant, respondent or advisor")
        .option("status", nil, ACON::Input::Option::Value[:required], "open or closed")
        .option("opened", nil, ACON::Input::Option::Value[:required], "opened date, YYYY-MM-DD")
        .option("closed", nil, ACON::Input::Option::Value[:required], "closed date, YYYY-MM-DD")
        .option("description", nil, ACON::Input::Option::Value[:required], "what the matter is about")
        .option("outcome", nil, ACON::Input::Option::Value[:required], "how the matter ended")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      changes = {} of String => String
      FIELDS.each do |option, field|
        value = input.option(option).to_s
        changes[field] = value unless value.empty?
      end
      if changes.empty?
        output.puts "error: give at least one of --#{FIELDS.keys.join(", --")}"
        return ACON::Command::Status::FAILURE
      end

      result = Api.patch("/api/v1/matters/#{Api.path_segment(input.argument("matter").to_s)}", {matter: changes})
      if json?(input)
        output.puts result.to_pretty_json
      else
        RightDocuments.print_matter(output, result["matter"])
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "matters:update failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("parties", description: "List a matter's parties")]
  class PartiesCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      PartiesCommand.add_json_option(self)
      self.argument("matter", :required, "matter number or ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      result = Api.get("/api/v1/matters/#{Api.path_segment(input.argument("matter").to_s)}/parties")
      if json?(input)
        output.puts result.to_pretty_json
        return ACON::Command::Status::SUCCESS
      end

      parties = result["parties"]?.try(&.as_a?) || [] of JSON::Any
      output.puts "no parties" if parties.empty?
      parties.each do |party|
        output.puts "#{MatterText.s(party["id"]?)}\t#{MatterText.s(party["name"]?)}\t#{MatterText.humanize(MatterText.s(party["role"]?))}"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "parties failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("parties:add", description: "Add a party to a matter")]
  class PartiesAddCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      PartiesAddCommand.add_json_option(self)
      self
        .argument("matter", :required, "matter number or ID")
        .option("name", nil, ACON::Input::Option::Value[:required], "party name")
        .option("role", "r", ACON::Input::Option::Value[:required],
          "adverse_party, opposing_counsel, co_counsel, court, witness or other (default: adverse_party)")
        .option("email", nil, ACON::Input::Option::Value[:required], "email address")
        .option("address", nil, ACON::Input::Option::Value[:required], "postal address (use \\n for new lines)")
        .option("notes", nil, ACON::Input::Option::Value[:required], "notes")
        .option("entity", "e", ACON::Input::Option::Value[:required], "one of our companies (name or ID), if the party is one")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      name = input.option("name").to_s
      if name.empty?
        output.puts "error: --name is required"
        return ACON::Command::Status::FAILURE
      end

      party = {"name" => name, "role" => input.option("role").to_s.presence || "adverse_party"}
      if email = input.option("email").to_s.presence
        party["email"] = email
      end
      if address = input.option("address").to_s.presence
        party["address"] = address.gsub("\\n", "\n")
      end
      if notes = input.option("notes").to_s.presence
        party["notes"] = notes
      end
      if entity = input.option("entity").to_s.presence
        party["entity_id"] = RightDocuments.resolve_entity_id(entity)
      end

      result = Api.post("/api/v1/matters/#{Api.path_segment(input.argument("matter").to_s)}/parties", {party: party})
      if json?(input)
        output.puts result.to_pretty_json
      else
        added = result["party"]
        output.puts "#{MatterText.s(added["id"]?)}\t#{MatterText.s(added["name"]?)}\t#{MatterText.humanize(MatterText.s(added["role"]?))}"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "parties:add failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("parties:remove", description: "Remove a party from a matter")]
  class PartiesRemoveCommand < ACON::Command
    protected def configure : Nil
      self
        .argument("matter", :required, "matter number or ID")
        .argument("party", :required, "party ID (see `rightdocuments parties MATTER`)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      matter = Api.path_segment(input.argument("matter").to_s)
      party = Api.path_segment(input.argument("party").to_s)
      Api.delete("/api/v1/matters/#{matter}/parties/#{party}")
      output.puts "Removed."
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "parties:remove failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end
end
