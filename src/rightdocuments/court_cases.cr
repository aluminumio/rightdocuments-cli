# Court cases and court filings. The case number and filed date are facts:
# only a filing with the court's endorsed copy sets them. There is no
# command that sets them by hand.
module RightDocuments
  module CourtCaseText
    def self.fact(court_case : JSON::Any, field : String) : String
      value = MatterText.s(court_case.dig?("facts", field, "value"))
      return "— (not filed yet)" if value.empty?
      source = court_case.dig?("facts", field, "source_document")
      source ? "#{value} (from #{MatterText.s(source["name"]?)}, #{MatterText.s(source["id"]?)})" : value
    end

    def self.filing_line(filing : JSON::Any) : String
      fees = filing["fees_cents"]?.try(&.as_i?).try { |cents| "$%.2f" % (cents / 100.0) } || "—"
      "#{MatterText.s(filing["id"]?)}\t#{MatterText.s(filing["kind"]?).ljust(10)}\t#{MatterText.s(filing["status"]?).ljust(9)}\t" \
      "#{MatterText.or_dash(filing["filed_on"]?).ljust(10)}\t#{fees}\t#{MatterText.s(filing.dig?("document", "name"))}"
    end

    def self.print(output : ACON::Output::Interface, court_case : JSON::Any) : Nil
      output.puts "court: #{MatterText.s(court_case["court_name"]?)} (#{MatterText.s(court_case["court_code"]?)})"
      output.puts "matter: #{MatterText.s(court_case.dig?("matter", "number"))} #{MatterText.s(court_case.dig?("matter", "name"))}"
      output.puts "case type: #{MatterText.s(court_case["case_type"]?)}#{court_case["jury_demanded"]?.try(&.as_bool?) ? ", jury demanded" : ""}"
      output.puts "status: #{MatterText.s(court_case["status"]?)}"
      output.puts "case number: #{fact(court_case, "case_number")}"
      output.puts "filed: #{fact(court_case, "filed_on")}"
      output.puts "efsp: #{MatterText.or_dash(court_case["efsp"]?)}#{(ref = MatterText.s(court_case["efsp_reference"]?)).empty? ? "" : " (#{ref})"}"
      output.puts "id: #{MatterText.s(court_case["id"]?)}"
      filings = court_case["filings"]?.try(&.as_a?) || [] of JSON::Any
      output.puts "filings:#{filings.empty? ? " none" : ""}"
      filings.each { |filing| output.puts "  - #{filing_line(filing)}" }
    end
  end

  @[ACONA::AsCommand("cases:open", description: "Open a court case on a matter, before filing (venue only)")]
  class CasesOpenCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      CasesOpenCommand.add_json_option(self)
      self
        .argument("matter", :required, "matter number (e.g. 0004-001) or ID")
        .option("court", nil, ACON::Input::Option::Value[:required], "court name, e.g. \"Superior Court of California, County of San Francisco\"")
        .option("court-code", nil, ACON::Input::Option::Value[:required], "court code, e.g. ca_sf_superior")
        .option("type", nil, ACON::Input::Option::Value[:required], "case type: limited, unlimited or other")
        .option("jury", nil, ACON::Input::Option::Value[:none], "a jury is demanded")
        .option("efsp", nil, ACON::Input::Option::Value[:required], "e-filing service provider")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      court = input.option("court").to_s
      code = input.option("court-code").to_s
      type = input.option("type").to_s
      if court.empty? || code.empty? || type.empty?
        output.puts "error: --court, --court-code and --type are required"
        return ACON::Command::Status::FAILURE
      end

      body = {
        "court_name"    => JSON::Any.new(court),
        "court_code"    => JSON::Any.new(code),
        "case_type"     => JSON::Any.new(type),
        "jury_demanded" => JSON::Any.new(input.option("jury", Bool)),
      }
      if efsp = input.option("efsp").to_s.presence
        body["efsp"] = JSON::Any.new(efsp)
      end
      matter = Api.path_segment(input.argument("matter").to_s)
      result = Api.post("/api/v1/matters/#{matter}/court_cases", {court_case: body})
      if json?(input)
        output.puts result.to_pretty_json
      else
        CourtCaseText.print(output, result["court_case"])
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "cases:open failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("cases:info", description: "Show a court case: facts with their source documents, and filings")]
  class CasesInfoCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      CasesInfoCommand.add_json_option(self)
      self.argument("case", :required, "court case ID, case number, or matter number (when the matter has one case)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      result = Api.get("/api/v1/court_cases/#{Api.path_segment(input.argument("case").to_s)}")
      if json?(input)
        output.puts result.to_pretty_json
      else
        CourtCaseText.print(output, result["court_case"])
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "cases:info failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("filings:add", description: "Record a court filing; with --endorsed, set the case number and filed date")]
  class FilingsAddCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      FilingsAddCommand.add_json_option(self)
      self
        .argument("case", :required, "court case ID, case number, or matter number (when the matter has one case)")
        .option("document", "d", ACON::Input::Option::Value[:required], "ID of the as-filed document, filed under the case's matter")
        .option("kind", "k", ACON::Input::Option::Value[:required], "complaint or other")
        .option("fees", nil, ACON::Input::Option::Value[:required], "filing fees, e.g. 435.00")
        .option("efsp-ref", nil, ACON::Input::Option::Value[:required], "e-filing envelope or reference number")
        .option("endorsed", nil, ACON::Input::Option::Value[:required], "path to the court's endorsed (stamped) PDF")
        .option("case-number", nil, ACON::Input::Option::Value[:required], "case number on the endorsed caption (needs --endorsed)")
        .option("filed", nil, ACON::Input::Option::Value[:required], "date of the clerk's stamp, YYYY-MM-DD (needs --endorsed)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      document = input.option("document").to_s
      kind = input.option("kind").to_s
      if document.empty? || kind.empty?
        output.puts "error: --document and --kind are required"
        return ACON::Command::Status::FAILURE
      end
      endorsed = input.option("endorsed").to_s.presence
      if endorsed && !File.file?(endorsed)
        output.puts "error: #{endorsed}: no such file"
        return ACON::Command::Status::FAILURE
      end

      fields = {"document" => document, "kind" => kind}
      {"fees" => "fees", "efsp-ref" => "efsp_reference", "case-number" => "case_number", "filed" => "filed_on"}.each do |option, field|
        if value = input.option(option).to_s.presence
          fields[field] = value
        end
      end
      files = endorsed ? {"endorsed" => endorsed} : {} of String => String
      court_case = Api.path_segment(input.argument("case").to_s)
      result = Api.multipart("/api/v1/court_cases/#{court_case}/filings", fields, files)
      if json?(input)
        output.puts result.to_pretty_json
      else
        output.puts CourtCaseText.filing_line(result["filing"])
        output.puts ""
        CourtCaseText.print(output, result["court_case"])
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "filings:add failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("filings:list", description: "List a court case's filings")]
  class FilingsListCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      FilingsListCommand.add_json_option(self)
      self.argument("case", :required, "court case ID, case number, or matter number (when the matter has one case)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      result = Api.get("/api/v1/court_cases/#{Api.path_segment(input.argument("case").to_s)}/filings")
      if json?(input)
        output.puts result.to_pretty_json
        return ACON::Command::Status::SUCCESS
      end

      filings = result["filings"]?.try(&.as_a?) || [] of JSON::Any
      output.puts "no filings" if filings.empty?
      filings.each { |filing| output.puts CourtCaseText.filing_line(filing) }
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "filings:list failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end
end
