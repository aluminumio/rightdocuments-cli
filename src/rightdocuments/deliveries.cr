# How a document was sent: email, mail, courier, by hand.
module RightDocuments
  module DeliveryText
    def self.line(delivery : JSON::Any) : String
      when_sent = MatterText.s(delivery["sent_at"]?)[0, 10]
      recipient = MatterText.s(delivery["recipient_name"]?).presence ||
                  MatterText.s(delivery["recipient_email"]?).presence || "(no recipient)"
      via = [MatterText.s(delivery["channel"]?), MatterText.s(delivery["provider"]?)].reject(&.empty?).join("/")
      "#{MatterText.s(delivery["id"]?)}\t#{when_sent}\t#{via}\t#{MatterText.s(delivery["status"]?)}\t#{recipient}"
    end
  end

  @[ACONA::AsCommand("deliveries", description: "List how a document was sent")]
  class DeliveriesCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DeliveriesCommand.add_json_option(self)
      self.argument("document", :required, "document ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      result = Api.get("/api/v1/documents/#{Api.path_segment(input.argument("document").to_s)}/deliveries")
      if json?(input)
        output.puts result.to_pretty_json
        return ACON::Command::Status::SUCCESS
      end

      deliveries = result["deliveries"]?.try(&.as_a?) || [] of JSON::Any
      output.puts "no deliveries" if deliveries.empty?
      deliveries.each { |delivery| output.puts DeliveryText.line(delivery) }
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "deliveries failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deliveries:add", description: "Log that a document was sent")]
  class DeliveriesAddCommand < ACON::Command
    include JSONOption

    OPTIONS = {
      "provider"    => "provider",
      "provider-id" => "provider_id",
      "tracking"    => "tracking_url",
      "status"      => "status",
      "sent"        => "sent_at",
      "to"          => "recipient_name",
      "email"       => "recipient_email",
      "address"     => "recipient_address",
      "notes"       => "notes",
      "party"       => "party_id",
    }

    protected def configure : Nil
      DeliveriesAddCommand.add_json_option(self)
      self
        .argument("document", :required, "document ID")
        .option("channel", nil, ACON::Input::Option::Value[:required], "email, mail, courier, hand or other")
        .option("provider", nil, ACON::Input::Option::Value[:required], "manual, smtp, lob, dhl, fedex or other")
        .option("provider-id", nil, ACON::Input::Option::Value[:required], "the provider's ID (e.g. a Lob letter ID)")
        .option("tracking", nil, ACON::Input::Option::Value[:required], "tracking URL")
        .option("status", nil, ACON::Input::Option::Value[:required], "queued, sent, delivered, failed or unknown (default: sent)")
        .option("sent", nil, ACON::Input::Option::Value[:required], "when it was sent, e.g. 2026-09-02 (default: now)")
        .option("to", nil, ACON::Input::Option::Value[:required], "recipient name")
        .option("email", nil, ACON::Input::Option::Value[:required], "recipient email (email channel)")
        .option("address", nil, ACON::Input::Option::Value[:required], "recipient address (mail/courier; use \\n for new lines)")
        .option("party", nil, ACON::Input::Option::Value[:required], "party ID of the document's matter; fills the recipient")
        .option("notes", nil, ACON::Input::Option::Value[:required], "notes, e.g. \"certified, return receipt\"")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      channel = input.option("channel").to_s
      if channel.empty?
        output.puts "error: --channel is required"
        return ACON::Command::Status::FAILURE
      end

      delivery = {"channel" => channel}
      OPTIONS.each do |option, field|
        value = input.option(option).to_s
        delivery[field] = (field == "recipient_address" ? value.gsub("\\n", "\n") : value) unless value.empty?
      end
      result = Api.post("/api/v1/documents/#{Api.path_segment(input.argument("document").to_s)}/deliveries", {delivery: delivery})
      if json?(input)
        output.puts result.to_pretty_json
      else
        output.puts DeliveryText.line(result["delivery"])
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "deliveries:add failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deliveries:update", description: "Update a delivery, e.g. mark it delivered")]
  class DeliveriesUpdateCommand < ACON::Command
    include JSONOption

    OPTIONS = {"status" => "status", "delivered" => "delivered_at", "tracking" => "tracking_url",
               "provider-id" => "provider_id", "notes" => "notes"}

    protected def configure : Nil
      DeliveriesUpdateCommand.add_json_option(self)
      self
        .argument("document", :required, "document ID")
        .argument("delivery", :required, "delivery ID (see `rightdocuments deliveries DOCUMENT`)")
        .option("status", nil, ACON::Input::Option::Value[:required], "queued, sent, delivered, failed or unknown")
        .option("delivered", nil, ACON::Input::Option::Value[:required], "when it was delivered, e.g. 2026-09-08")
        .option("tracking", nil, ACON::Input::Option::Value[:required], "tracking URL")
        .option("provider-id", nil, ACON::Input::Option::Value[:required], "the provider's ID")
        .option("notes", nil, ACON::Input::Option::Value[:required], "notes")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      changes = {} of String => String
      OPTIONS.each do |option, field|
        value = input.option(option).to_s
        changes[field] = value unless value.empty?
      end
      if changes.empty?
        output.puts "error: give at least one of --#{OPTIONS.keys.join(", --")}"
        return ACON::Command::Status::FAILURE
      end

      document = Api.path_segment(input.argument("document").to_s)
      delivery = Api.path_segment(input.argument("delivery").to_s)
      result = Api.patch("/api/v1/documents/#{document}/deliveries/#{delivery}", {delivery: changes})
      if json?(input)
        output.puts result.to_pretty_json
      else
        output.puts DeliveryText.line(result["delivery"])
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "deliveries:update failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end
end
