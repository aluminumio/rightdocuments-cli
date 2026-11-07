# Litigation workflows: the playbooks, a matter's workflow runs, and starting
# a playbook on a matter. The fit of a playbook is advice, as on the web
# confirm page: the server refuses only a placeholder, a closed matter, a
# missing court case, or a playbook that is already running.
module RightDocuments
  module WorkflowText
    NEXT_STEPS = 3

    # "draft", or "reviewed by X on D".
    def self.review(playbook : JSON::Any) : String
      status = MatterText.s(playbook["review_status"]?)
      by = MatterText.s(playbook["reviewed_by"]?)
      on = MatterText.s(playbook["reviewed_on"]?)
      return status.presence || "—" if by.empty? && on.empty?
      [status.presence || "reviewed", by.empty? ? nil : "by #{by}", on.empty? ? nil : "on #{on}"].compact.join(" ")
    end

    def self.playbook_line(playbook : JSON::Any) : String
      name = MatterText.s(playbook["name"]?)
      stub = playbook["stub"]?.try(&.as_bool?) && !name.downcase.includes?("stub") ? " (stub)" : ""
      "  #{MatterText.s(playbook["key"]?).ljust(32)}#{MatterText.s(playbook["version"]?).ljust(9)}" \
      "#{review(playbook).ljust(36)}#{name}#{stub}"
    end

    def self.steps(run : JSON::Any) : Array(JSON::Any)
      run["open_steps"]?.try(&.as_a?) || [] of JSON::Any
    end

    # "Serve the complaint (attorney, due 2026-11-20)".
    def self.step(step : JSON::Any) : String
      details = [MatterText.s(step["actor"]?), MatterText.s(step["due_on"]?).presence.try { |due| "due #{due}" }]
        .compact.reject(&.empty?)
      "#{MatterText.s(step["name"]?)}#{details.empty? ? "" : " (#{details.join(", ")})"}"
    end

    # The run's line and its next open steps.
    def self.run_lines(run : JSON::Any, limit : Int32 = NEXT_STEPS) : Array(String)
      started = MatterText.s(run["started_at"]?)[0, 10]
      lines = ["  #{MatterText.s(run["id"]?)}  #{MatterText.s(run["name"]?)}  " \
               "#{MatterText.s(run["playbook_key"]?)}@#{MatterText.s(run["playbook_version"]?)}  " \
               "#{MatterText.s(run["status"]?)}  started #{started.presence || "—"}"]
      open_steps = steps(run)
      open_steps.first(limit).each { |step| lines << "    next: #{step(step)}" }
      lines << "    (#{open_steps.size - limit} more open steps)" if open_steps.size > limit
      lines
    end

    def self.reasons(record : JSON::Any?) : Array(String)
      list = record.try(&.as_h?).try(&.["reasons"]?).try(&.as_a?) || [] of JSON::Any
      list.map { |reason| "#{MatterText.s(reason["result"]?)}: #{MatterText.s(reason["text"]?)}" }
    end

    # The court case a playbook would use, by case number when it has one.
    def self.court_case(playbook : JSON::Any, case_numbers : Hash(String, String)) : String?
      ids = playbook["court_case_ids"]?.try(&.as_a?).try(&.map(&.as_s)) || [] of String
      if ids.empty?
        return playbook["needs_court_case"]?.try(&.as_bool?) ? "needed; the matter has none (`rightdocuments cases:open`)" : nil
      end
      labels = ids.map { |id| (number = case_numbers[id]?.presence) ? "#{number} (#{id})" : "#{id} (no case number yet)" }
      ids.size > 1 ? "one of #{labels.join(", ")} (pass --case)" : labels.first
    end

    def self.chooser_lines(playbook : JSON::Any, case_numbers : Hash(String, String)) : Array(String)
      lines = ["  #{MatterText.s(playbook["key"]?).ljust(32)}#{MatterText.s(playbook["fit_word"]?).ljust(28)}" \
               "#{MatterText.s(playbook["name"]?)}"]
      if court_case = court_case(playbook, case_numbers)
        lines << "    case: #{court_case}"
      end
      reasons(playbook).each { |reason| lines << "    #{reason}" }
      lines
    end
  end

  module WorkflowStart
    ADVICE_FITS = {"does_not_fit", "unknown"}

    enum Decision
      Start
      Ask
      Refuse
    end

    # Start at once when the playbook fits (or is not in the chooser: the
    # server answers for it); else --yes starts, a terminal asks, and a
    # non-interactive run refuses.
    def self.decision(fit : String?, yes : Bool, interactive : Bool) : Decision
      return Decision::Start if yes || !ADVICE_FITS.includes?(fit)
      interactive ? Decision::Ask : Decision::Refuse
    end
  end

  def self.error_output(output : ACON::Output::Interface) : ACON::Output::Interface
    output.is_a?(ACON::Output::ConsoleOutputInterface) ? output.error_output : output
  end

  @[ACONA::AsCommand("playbooks", description: "List the litigation playbooks and their review status")]
  class PlaybooksCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      PlaybooksCommand.add_json_option(self)
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      result = Api.get("/api/v1/playbooks")
      if json?(input)
        output.puts result.to_pretty_json
        return ACON::Command::Status::SUCCESS
      end

      playbooks = result["playbooks"]?.try(&.as_a?) || [] of JSON::Any
      output.puts ""
      output.puts "  #{"Key".ljust(32)}#{"Version".ljust(9)}#{"Review".ljust(36)}Name"
      output.puts "  #{"─" * 100}"
      playbooks.each { |playbook| output.puts WorkflowText.playbook_line(playbook) }
      output.puts ""
      output.puts "  #{playbooks.size} playbooks"
      output.puts ""
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "playbooks failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("workflows", description: "Show a matter's workflows and the playbooks that fit it")]
  class WorkflowsCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      WorkflowsCommand.add_json_option(self)
      self.argument("matter", :required, "matter number (e.g. 0004-001) or ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      matter = Api.path_segment(input.argument("matter").to_s)
      result = Api.get("/api/v1/matters/#{matter}/workflows")
      if json?(input)
        output.puts result.to_pretty_json
        return ACON::Command::Status::SUCCESS
      end

      runs = result["workflow_runs"]?.try(&.as_a?) || [] of JSON::Any
      output.puts "workflows:#{runs.empty? ? " none" : ""}"
      runs.each { |run| WorkflowText.run_lines(run).each { |line| output.puts line } }

      playbooks = result["playbooks"]?.try(&.as_a?) || [] of JSON::Any
      case_numbers = playbooks.any? { |p| p["court_case_ids"]?.try(&.as_a?).try(&.any?) } ? case_numbers(matter) : {} of String => String
      output.puts "playbooks:#{playbooks.empty? ? " none" : ""}"
      playbooks.each { |playbook| WorkflowText.chooser_lines(playbook, case_numbers).each { |line| output.puts line } }
      output.puts "Start one with `rightdocuments workflows:start #{input.argument("matter")} --playbook KEY`." unless playbooks.empty?
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "workflows failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end

    # Court case ID => case number, from the matter.
    private def case_numbers(matter : String) : Hash(String, String)
      cases = Api.get("/api/v1/matters/#{matter}")["matter"]["court_cases"]?.try(&.as_a?) || [] of JSON::Any
      cases.to_h { |c| {MatterText.s(c["id"]?), MatterText.s(c["case_number"]?)} }
    end
  end

  @[ACONA::AsCommand("workflows:start", description: "Start a playbook on a matter (asks first when it may not fit)")]
  class WorkflowsStartCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      WorkflowsStartCommand.add_json_option(self)
      self
        .argument("matter", :required, "matter number (e.g. 0004-001) or ID")
        .option("playbook", "p", ACON::Input::Option::Value[:required], "playbook key (see `rightdocuments playbooks`)")
        .option("playbook-version", nil, ACON::Input::Option::Value[:required], "playbook version to pin (default: the latest; --version is the CLI's own)")
        .option("case", nil, ACON::Input::Option::Value[:required], "court case ID or case number, for a playbook that belongs to a court case")
        .option("yes", "y", ACON::Input::Option::Value[:none], "start without asking when the playbook may not fit")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      errors = RightDocuments.error_output(output)
      key = input.option("playbook").to_s
      if key.empty?
        errors.puts "error: --playbook is required (see `rightdocuments playbooks`)"
        return ACON::Command::Status::FAILURE
      end

      matter = Api.path_segment(input.argument("matter").to_s)
      fits = Api.get("/api/v1/matters/#{matter}/workflows")["playbooks"]?.try(&.as_a?) || [] of JSON::Any
      fit = fits.find { |p| MatterText.s(p["key"]?) == key }
      unless confirmed?(input, output, errors, fit)
        return ACON::Command::Status::FAILURE
      end

      body = {"playbook_key" => key}
      if version = input.option("playbook-version").to_s.presence
        body["version"] = version
      end
      if court_case = input.option("case").to_s.presence
        body["court_case_id"] = court_case
      end
      result = Api.post("/api/v1/matters/#{matter}/workflows", body)
      if json?(input)
        output.puts result.to_pretty_json
        return ACON::Command::Status::SUCCESS
      end

      run = result["workflow_run"]
      output.puts "started #{MatterText.s(run["name"]?)}"
      output.puts "id: #{MatterText.s(run["id"]?)}"
      output.puts "playbook: #{MatterText.s(run["playbook_key"]?)}@#{MatterText.s(run["playbook_version"]?)}"
      steps = WorkflowText.steps(run)
      output.puts "open steps:#{steps.empty? ? " none" : ""}"
      steps.first(WorkflowText::NEXT_STEPS).each { |step| output.puts "  - #{WorkflowText.step(step)}" }
      output.puts "  (#{steps.size - WorkflowText::NEXT_STEPS} more; see `rightdocuments workflows #{input.argument("matter")}`)" if steps.size > WorkflowText::NEXT_STEPS
      ACON::Command::Status::SUCCESS
    rescue ex : Api::Error
      errors = RightDocuments.error_output(output)
      errors.puts "workflows:start failed: #{ex.message}"
      WorkflowText.reasons(ex.body).each { |reason| errors.puts "  #{reason}" }
      ACON::Command::Status::FAILURE
    rescue ex
      RightDocuments.error_output(output).puts "workflows:start failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end

    # Prints the fit and its reasons when the playbook may not fit, then
    # decides: --yes starts, a terminal asks, --no-interaction refuses.
    private def confirmed?(input, output, errors, fit : JSON::Any?) : Bool
      status = fit.try { |f| MatterText.s(f["fit"]?) }
      if WorkflowStart::ADVICE_FITS.includes?(status)
        errors.puts "#{MatterText.s(fit.try(&.["name"]?))}: #{MatterText.s(fit.try(&.["fit_word"]?))}"
        WorkflowText.reasons(fit).each { |reason| errors.puts "  #{reason}" }
      end

      case WorkflowStart.decision(status, input.option("yes", Bool), input.interactive?)
      in .start?
        true
      in .refuse?
        errors.puts "Not started: the playbook may not fit. Run again with --yes to start it anyway."
        false
      in .ask?
        question = ACON::Question::Confirmation.new("Start it anyway? [y/N] ", false)
        started = helper(ACON::Helper::Question).ask(input, output, question).as(Bool)
        errors.puts "Not started." unless started
        started
      end
    end
  end
end
