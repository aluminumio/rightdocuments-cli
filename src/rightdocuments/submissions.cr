# Submissions: a document sent to an authority (a court, a secretary of
# state, the IRS, another agency) or a party, and what came back. Facts
# (case number and filed date, company file number and formation date, EIN)
# come only from an acceptance or a filed copy, with the returned file.
module RightDocuments
  module SubmissionText
    RECIPIENTS = {"sos" => "secretary_of_state", "agency" => "other_agency"}

    def self.line(submission : JSON::Any) : String
      submitted = MatterText.s(submission["submitted_at"]?)[0, 16]
      to = MatterText.s(submission["recipient_name"]?).presence || MatterText.s(submission["recipient_kind"]?)
      via = [MatterText.s(submission["channel"]?), MatterText.s(submission["channel_provider"]?)].reject(&.empty?).join("/")
      filed = MatterText.s(submission["filed_on"]?)
      "#{MatterText.s(submission["id"]?)}\t#{MatterText.s(submission["status"]?).ljust(9)}\t#{submitted}\t#{via.presence || "—"}\t" \
      "#{filed.empty? ? "—" : "filed #{filed}"}\t#{to}"
    end

    def self.print(output : ACON::Output::Interface, submission : JSON::Any) : Nil
      output.puts "document: #{MatterText.s(submission.dig?("document", "name"))} (#{MatterText.s(submission.dig?("document", "id"))})"
      output.puts "to: #{MatterText.s(submission["recipient_kind"]?)} #{MatterText.s(submission["recipient_name"]?)} #{MatterText.s(submission["jurisdiction"]?)}".rstrip
      if court_case = submission["court_case"]?.try(&.as_h?)
        output.puts "court case: #{court_case["case_number"]?.try(&.as_s?) || "(no case number yet)"} (#{court_case["id"]?.try(&.as_s?)})"
      end
      output.puts "via: #{MatterText.or_dash(submission["channel"]?)} #{MatterText.s(submission["channel_provider"]?)}".rstrip
      output.puts "reference: #{MatterText.or_dash(submission["reference"]?)}"
      output.puts "status: #{MatterText.s(submission["status"]?)}"
      output.puts "submitted: #{MatterText.or_dash(submission["submitted_at"]?)}"
      output.puts "received: #{MatterText.or_dash(submission["received_at"]?)}" if submission["received_at"]?.try(&.as_s?)
      if submission["status"]?.try(&.as_s?) == "accepted" || submission["filed_on"]?.try(&.as_s?)
        basis = MatterText.s(submission["filed_on_basis"]?)
        output.puts "filed: #{MatterText.s(submission["filed_on"]?).presence || "not settled"}#{basis.empty? ? "" : " (#{basis})"}"
      end
      if warning = submission["filed_on_warning"]?.try(&.as_s?)
        output.puts "warning: #{warning}"
      end
      if reason = submission["rejection_reason"]?.try(&.as_s?)
        output.puts "rejected: #{reason}"
      end
      (submission["facts"]?.try(&.as_a?) || [] of JSON::Any).each do |fact|
        output.puts "proved: #{MatterText.s(fact["target"]?)} #{MatterText.s(fact["field_name"]?)} = #{MatterText.s(fact["new_value"]?)}"
      end
      if next_action = submission["next_action"]?.try(&.as_s?)
        output.puts "next: #{next_action}"
      end
      output.puts "id: #{MatterText.s(submission["id"]?)}"
      events = submission["events"]?.try(&.as_a?) || [] of JSON::Any
      output.puts "history:#{events.empty? ? " none" : ""}"
      events.each do |event|
        file = event.dig?("file", "filename").try(&.as_s?)
        reason = event["reason"]?.try(&.as_s?)
        output.puts "  - #{MatterText.s(event["occurred_at"]?)}\t#{MatterText.s(event["action"]?)}#{file ? "\t#{file}" : ""}#{reason ? "\t(#{reason})" : ""}"
      end
    end

    def self.print_plan(output : ACON::Output::Interface, plan : JSON::Any) : Nil
      output.puts "Recording this will:"
      (plan["consequences"]?.try(&.as_a?) || [] of JSON::Any).each { |line| output.puts "  - #{MatterText.s(line)}" }
      (plan["warnings"]?.try(&.as_a?) || [] of JSON::Any).each { |line| output.puts "warning: #{MatterText.s(line)}" }
      output.puts "(dry run: nothing was recorded)"
    end

    # Copies the options that have a value into fields (option => API field).
    def self.collect(input : ACON::Input::Interface, map : Hash(String, String), fields : Hash(String, String)) : Hash(String, String)
      map.each do |option, field|
        if value = input.option(option).to_s.presence
          fields[field] = value
        end
      end
      fields
    end

    # Posts what came back. Prints the plan on --dry-run, else the submission.
    def self.record(input, output, json : Bool, path : String, fields : Hash(String, String), file : String?) : ACON::Command::Status
      if file && !File.file?(file)
        output.puts "error: #{file}: no such file"
        return ACON::Command::Status::FAILURE
      end
      fields["dry_run"] = "true" if input.option("dry-run", Bool)
      files = file ? {"file" => file} : {} of String => String
      result = Api.multipart(path, fields, files)
      if json
        output.puts result.to_pretty_json
      elsif plan = result["plan"]?
        print_plan(output, plan)
      else
        print(output, result["submission"])
      end
      ACON::Command::Status::SUCCESS
    end
  end

  @[ACONA::AsCommand("submissions", description: "List a document's submissions (to a court, an agency or a party)")]
  class SubmissionsCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      SubmissionsCommand.add_json_option(self)
      self.argument("document", :required, "document ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      result = Api.get("/api/v1/documents/#{Api.path_segment(input.argument("document").to_s)}/submissions")
      if json?(input)
        output.puts result.to_pretty_json
        return ACON::Command::Status::SUCCESS
      end

      submissions = result["submissions"]?.try(&.as_a?) || [] of JSON::Any
      output.puts "no submissions" if submissions.empty?
      submissions.each do |submission|
        output.puts SubmissionText.line(submission)
        if next_action = submission["next_action"]?.try(&.as_s?)
          output.puts "  next: #{next_action}"
        end
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "submissions failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("submissions:info", description: "Show a submission: status, history, and the facts it proved")]
  class SubmissionsInfoCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      SubmissionsInfoCommand.add_json_option(self)
      self.argument("submission", :required, "submission ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      result = Api.get("/api/v1/submissions/#{Api.path_segment(input.argument("submission").to_s)}")
      if json?(input)
        output.puts result.to_pretty_json
      else
        SubmissionText.print(output, result["submission"])
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "submissions:info failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("submissions:add", description: "Record that a document was sent to a court, an agency or a party")]
  class SubmissionsAddCommand < ACON::Command
    include JSONOption

    OPTIONS = {
      "name" => "recipient_name", "jurisdiction" => "jurisdiction", "channel" => "channel", "provider" => "channel_provider",
      "submitted" => "submitted_at", "reference" => "reference", "fees" => "fees", "notes" => "notes",
      "time-zone" => "time_zone", "case" => "court_case", "kind" => "filing_kind", "delivery" => "delivery_id",
    }

    protected def configure : Nil
      SubmissionsAddCommand.add_json_option(self)
      self
        .argument("document", :required, "document ID (the document as sent)")
        .option("to", nil, ACON::Input::Option::Value[:required], "court, sos (secretary of state), irs, agency or party")
        .option("name", nil, ACON::Input::Option::Value[:required], "recipient name, e.g. \"Delaware Division of Corporations\"")
        .option("jurisdiction", nil, ACON::Input::Option::Value[:required], "e.g. DE or CA (sets the time zone of times without an offset)")
        .option("channel", nil, ACON::Input::Option::Value[:required], "efsp, online_portal, mail, hand, email or other")
        .option("provider", nil, ACON::Input::Option::Value[:required], "e.g. \"One Legal\"")
        .option("submitted", nil, ACON::Input::Option::Value[:required], "when it was sent, e.g. 2026-10-10T22:40 (default: now)")
        .option("reference", nil, ACON::Input::Option::Value[:required], "envelope, order or transaction number")
        .option("fees", nil, ACON::Input::Option::Value[:required], "fees in dollars, e.g. 435.00")
        .option("notes", nil, ACON::Input::Option::Value[:required], "notes")
        .option("time-zone", nil, ACON::Input::Option::Value[:required], "e.g. America/New_York (default: the court's, or by jurisdiction)")
        .option("case", nil, ACON::Input::Option::Value[:required], "court case ID or case number (court; optional when the matter has one case)")
        .option("kind", nil, ACON::Input::Option::Value[:required], "court filing kind: complaint or other")
        .option("delivery", nil, ACON::Input::Option::Value[:required], "ID of a delivery of this document to link")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      to = input.option("to").to_s
      if to.empty?
        output.puts "error: --to is required (court, sos, irs, agency or party)"
        return ACON::Command::Status::FAILURE
      end

      body = SubmissionText.collect(input, OPTIONS, {"recipient_kind" => SubmissionText::RECIPIENTS[to]? || to})
      document = Api.path_segment(input.argument("document").to_s)
      result = Api.post("/api/v1/documents/#{document}/submissions", body)
      if json?(input)
        output.puts result.to_pretty_json
      else
        SubmissionText.print(output, result["submission"])
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "submissions:add failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("submissions:receipt", description: "Record a submission receipt (proves nothing; the submission stays open)")]
  class SubmissionsReceiptCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      SubmissionsReceiptCommand.add_json_option(self)
      self
        .argument("submission", :required, "submission ID")
        .option("file", nil, ACON::Input::Option::Value[:required], "path to the receipt")
        .option("reference", nil, ACON::Input::Option::Value[:required], "envelope or transaction number on the receipt")
        .option("notes", nil, ACON::Input::Option::Value[:required], "notes")
        .option("dry-run", nil, ACON::Input::Option::Value[:none], "show what would be recorded; record nothing")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      fields = SubmissionText.collect(input, {"reference" => "reference", "notes" => "notes"}, {} of String => String)
      id = Api.path_segment(input.argument("submission").to_s)
      SubmissionText.record(input, output, json?(input), "/api/v1/submissions/#{id}/receipt", fields, input.option("file").to_s.presence)
    rescue ex
      output.puts "submissions:receipt failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("submissions:accept", description: "Record the acceptance or the filed copy; it proves the facts")]
  class SubmissionsAcceptCommand < ACON::Command
    include JSONOption

    OPTIONS = {
      "returned" => "returned", "received" => "received_at", "filed" => "filed_on", "case-number" => "case_number",
      "file-number" => "file_number", "formation-date" => "formation_date", "ein" => "ein", "notes" => "notes",
    }

    protected def configure : Nil
      SubmissionsAcceptCommand.add_json_option(self)
      self
        .argument("submission", :required, "submission ID")
        .option("copy", nil, ACON::Input::Option::Value[:required], "path to the returned file (required; a PDF for a filed or certified copy)")
        .option("returned", nil, ACON::Input::Option::Value[:required], "filed_copy (default), acceptance (court confirmation) or certified_copy")
        .option("received", nil, ACON::Input::Option::Value[:required], "the authority's received date and time, e.g. 2026-10-10T23:00")
        .option("filed", nil, ACON::Input::Option::Value[:required], "the date on the stamp, YYYY-MM-DD")
        .option("case-number", nil, ACON::Input::Option::Value[:required], "court: the case number on the endorsed copy")
        .option("file-number", nil, ACON::Input::Option::Value[:required], "secretary of state: the company's file number")
        .option("formation-date", nil, ACON::Input::Option::Value[:required], "secretary of state: the formation date, YYYY-MM-DD")
        .option("ein", nil, ACON::Input::Option::Value[:required], "IRS: the EIN on the CP 575 or 147C letter")
        .option("notes", nil, ACON::Input::Option::Value[:required], "notes")
        .option("dry-run", nil, ACON::Input::Option::Value[:none], "show what would be recorded; record nothing")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      copy = input.option("copy").to_s.presence
      unless copy
        output.puts "error: --copy is required (the file that came back)"
        return ACON::Command::Status::FAILURE
      end

      fields = SubmissionText.collect(input, OPTIONS, {} of String => String)
      id = Api.path_segment(input.argument("submission").to_s)
      SubmissionText.record(input, output, json?(input), "/api/v1/submissions/#{id}/accept", fields, copy)
    rescue ex
      output.puts "submissions:accept failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("submissions:reject", description: "Record a rejection (proves nothing; resubmit with submissions:add)")]
  class SubmissionsRejectCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      SubmissionsRejectCommand.add_json_option(self)
      self
        .argument("submission", :required, "submission ID")
        .option("reason", nil, ACON::Input::Option::Value[:required], "the reason the authority gave (required)")
        .option("file", nil, ACON::Input::Option::Value[:required], "path to the rejection notice")
        .option("rejected", nil, ACON::Input::Option::Value[:required], "when it was rejected, e.g. 2026-10-12T09:00 (default: now)")
        .option("dry-run", nil, ACON::Input::Option::Value[:none], "show what would be recorded; record nothing")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      if input.option("reason").to_s.empty?
        output.puts "error: --reason is required"
        return ACON::Command::Status::FAILURE
      end

      fields = SubmissionText.collect(input, {"reason" => "reason", "rejected" => "rejected_at"}, {} of String => String)
      id = Api.path_segment(input.argument("submission").to_s)
      SubmissionText.record(input, output, json?(input), "/api/v1/submissions/#{id}/reject", fields, input.option("file").to_s.presence)
    rescue ex
      output.puts "submissions:reject failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("submissions:correct", description: "Correct a submission; the correction is logged with its reason")]
  class SubmissionsCorrectCommand < ACON::Command
    include JSONOption

    OPTIONS = {
      "submitted" => "submitted_at", "received" => "received_at", "filed" => "filed_on", "reference" => "reference",
      "channel" => "channel", "provider" => "channel_provider", "name" => "recipient_name", "jurisdiction" => "jurisdiction",
      "fees" => "fees", "notes" => "notes", "rejection-reason" => "rejection_reason", "case-number" => "case_number",
      "file-number" => "file_number", "formation-date" => "formation_date", "ein" => "ein",
    }

    protected def configure : Nil
      SubmissionsCorrectCommand.add_json_option(self)
      self
        .argument("submission", :required, "submission ID")
        .option("reason", nil, ACON::Input::Option::Value[:required], "why it is corrected (required)")
        .option("withdraw", nil, ACON::Input::Option::Value[:none], "withdraw an open submission")
      OPTIONS.each_key do |option|
        self.option(option, nil, ACON::Input::Option::Value[:required], "new #{OPTIONS[option].gsub('_', ' ')}")
      end
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      reason = input.option("reason").to_s
      if reason.empty?
        output.puts "error: --reason is required"
        return ACON::Command::Status::FAILURE
      end

      body = SubmissionText.collect(input, OPTIONS, {"reason" => reason})
      body["status"] = "withdrawn" if input.option("withdraw", Bool)
      result = Api.post("/api/v1/submissions/#{Api.path_segment(input.argument("submission").to_s)}/correct", body)
      if json?(input)
        output.puts result.to_pretty_json
      else
        SubmissionText.print(output, result["submission"])
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "submissions:correct failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end
end
