# Client commands. The engagement date is not settable here: an executed
# engagement letter sets it.
module RightDocuments
  # Prints one client.
  def self.print_client(output : ACON::Output::Interface, client : JSON::Any) : Nil
    output.puts "number: #{MatterText.s(client["number"]?)}"
    output.puts "name: #{MatterText.s(client["name"]?)}"
    output.puts "type: #{MatterText.s(client["client_type"]?)}"
    output.puts "status: #{MatterText.s(client["status"]?)}"
    output.puts "engaged: #{MatterText.or_dash(client["engaged_at"]?)}"
    output.puts "email: #{MatterText.s(client["email"]?)}"
    output.puts "phone: #{MatterText.or_dash(client["phone"]?)}"
    if address = client["address"]?.try(&.as_s?)
      output.puts "address: #{address.gsub("\n", ", ")}" unless address.empty?
    end
    if entity = client["entity"]?.try(&.as_h?)
      output.puts "company: #{entity["name"]?.try(&.as_s?)} (#{entity["id"]?.try(&.as_s?)})"
    end
    output.puts "documents: #{client["document_count"]?.try(&.as_i?) || 0}"
    output.puts "matters: #{client["matter_count"]?.try(&.as_i?) || 0}"
    if notes = client["notes"]?.try(&.as_s?)
      output.puts "notes: #{notes}" unless notes.empty?
    end
    output.puts "id: #{MatterText.s(client["id"]?)}"
  end

  # Options shared by clients:create and clients:update, mapped to API fields.
  module ClientOptions
    FIELDS = {
      "name"    => "name",
      "type"    => "client_type",
      "email"   => "email",
      "phone"   => "phone",
      "address" => "address",
      "notes"   => "notes",
      "entity"  => "entity",
    }

    def self.add(cmd : ACON::Command) : Nil
      cmd
        .option("name", nil, ACON::Input::Option::Value[:required], "client name")
        .option("type", "t", ACON::Input::Option::Value[:required], "business or individual")
        .option("email", nil, ACON::Input::Option::Value[:required], "email address")
        .option("phone", nil, ACON::Input::Option::Value[:required], "phone number")
        .option("address", nil, ACON::Input::Option::Value[:required], "postal address (use \\n for new lines)")
        .option("notes", nil, ACON::Input::Option::Value[:required], "notes")
        .option("entity", "e", ACON::Input::Option::Value[:required], "linked company (name or ID); \"\" unlinks it")
    end

    # Only the options that were given. An empty --entity is kept: it unlinks the company.
    def self.collect(input : ACON::Input::Interface) : Hash(String, String)
      changes = {} of String => String
      FIELDS.each do |option, field|
        value = input.option(option)
        next if value.nil?
        text = value.to_s.gsub("\\n", "\n")
        changes[field] = text unless text.empty? && option != "entity"
      end
      changes
    end
  end

  @[ACONA::AsCommand("clients", description: "List clients with their numbers")]
  class ClientsCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ClientsCommand.add_json_option(self)
      self
        .option("status", "s", ACON::Input::Option::Value[:required], "prospective, engaged or concluded")
        .option("type", "t", ACON::Input::Option::Value[:required], "business or individual")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      params = URI::Params.new
      if status = input.option("status").to_s.presence
        params["status"] = status
      end
      if type = input.option("type").to_s.presence
        params["client_type"] = type
      end
      result = Api.get("/api/v1/clients#{params.empty? ? "" : "?#{params}"}")
      if json?(input)
        output.puts result.to_pretty_json
        return ACON::Command::Status::SUCCESS
      end

      clients = result["clients"]?.try(&.as_a?) || [] of JSON::Any
      output.puts ""
      output.puts "  #{"No.".ljust(6)}#{"Name".ljust(32)}#{"Type".ljust(12)}#{"Status".ljust(13)}#{"Engaged".ljust(12)}#{"Docs".rjust(4)}  Email"
      output.puts "  #{"─" * 100}"
      clients.each do |client|
        output.puts "  #{MatterText.s(client["number"]?).ljust(6)}#{MatterText.s(client["name"]?)[0, 30].ljust(32)}" \
                    "#{MatterText.s(client["client_type"]?).ljust(12)}#{MatterText.s(client["status"]?).ljust(13)}" \
                    "#{MatterText.or_dash(client["engaged_at"]?).ljust(12)}" \
                    "#{(client["document_count"]?.try(&.as_i?) || 0).to_s.rjust(4)}  #{MatterText.s(client["email"]?)}"
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

  @[ACONA::AsCommand("clients:info", description: "Show a client by number, name or ID")]
  class ClientsInfoCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ClientsInfoCommand.add_json_option(self)
      self.argument("client", :required, "client number (4 or 0004), exact name, or ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      result = Api.get("/api/v1/clients/#{Api.path_segment(input.argument("client").to_s)}")
      if json?(input)
        output.puts result.to_pretty_json
      else
        RightDocuments.print_client(output, result["client"])
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "clients:info failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("clients:create", description: "Create a client (number is assigned on creation)")]
  class ClientsCreateCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ClientsCreateCommand.add_json_option(self)
      ClientOptions.add(self)
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      client = ClientOptions.collect(input)
      missing = {"name" => "name", "type" => "client_type", "email" => "email"}.reject { |_, field| client[field]?.presence }.keys
      unless missing.empty?
        output.puts "error: --#{missing.join(", --")} required"
        return ACON::Command::Status::FAILURE
      end

      result = Api.post("/api/v1/clients", {client: client})
      if json?(input)
        output.puts result.to_pretty_json
      else
        created = result["client"]
        output.puts "#{MatterText.s(created["number"]?)}\t#{MatterText.s(created["name"]?)}\t#{MatterText.s(created["status"]?)}"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "clients:create failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("clients:update", description: "Change a client's details or status (organization admins)")]
  class ClientsUpdateCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ClientsUpdateCommand.add_json_option(self)
      self.argument("client", :required, "client number, exact name, or ID")
      ClientOptions.add(self)
      self.option("status", "s", ACON::Input::Option::Value[:required], "prospective, engaged or concluded")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      changes = ClientOptions.collect(input)
      if status = input.option("status").to_s.presence
        changes["status"] = status
      end
      if changes.empty?
        output.puts "error: give at least one of --#{ClientOptions::FIELDS.keys.join(", --")}, --status"
        return ACON::Command::Status::FAILURE
      end

      result = Api.patch("/api/v1/clients/#{Api.path_segment(input.argument("client").to_s)}", {client: changes})
      if json?(input)
        output.puts result.to_pretty_json
      else
        RightDocuments.print_client(output, result["client"])
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "clients:update failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("clients:delete", description: "Delete a client without matters (organization admins)")]
  class ClientsDeleteCommand < ACON::Command
    protected def configure : Nil
      self
        .argument("client", :required, "client number, exact name, or ID")
        .option("yes", nil, ACON::Input::Option::Value[:none], "confirm: the client is deleted permanently")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      path = "/api/v1/clients/#{Api.path_segment(input.argument("client").to_s)}"
      client = Api.get(path)["client"]
      label = "#{MatterText.s(client["number"]?)} #{MatterText.s(client["name"]?)}"
      unless input.option("yes", Bool)
        output.puts "This deletes client #{label} permanently. Its documents stay, without a client."
        output.puts "Run again with --yes to delete."
        return ACON::Command::Status::FAILURE
      end

      Api.delete(path)
      output.puts "deleted #{label}"
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "clients:delete failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end
end
