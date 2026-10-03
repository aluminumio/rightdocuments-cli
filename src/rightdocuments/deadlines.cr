# Matter deadlines: response windows, filing dates, statutes of limitations.
module RightDocuments
  module DeadlineText
    def self.line(deadline : JSON::Any) : String
      "#{MatterText.s(deadline["id"]?)}\t#{MatterText.s(deadline["due_on"]?)}\t" \
      "#{MatterText.s(deadline["label"]?).ljust(18)}\t#{MatterText.s(deadline["name"]?)}"
    end
  end

  @[ACONA::AsCommand("deadlines", description: "List a matter's deadlines by due date")]
  class DeadlinesCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DeadlinesCommand.add_json_option(self)
      self.argument("matter", :required, "matter number (e.g. 0004-001) or ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      result = Api.get("/api/v1/matters/#{Api.path_segment(input.argument("matter").to_s)}/deadlines")
      if json?(input)
        output.puts result.to_pretty_json
        return ACON::Command::Status::SUCCESS
      end

      deadlines = result["deadlines"]?.try(&.as_a?) || [] of JSON::Any
      output.puts "no deadlines" if deadlines.empty?
      deadlines.each { |deadline| output.puts DeadlineText.line(deadline) }
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "deadlines failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deadlines:add", description: "Add a deadline to a matter")]
  class DeadlinesAddCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DeadlinesAddCommand.add_json_option(self)
      self
        .argument("matter", :required, "matter number or ID")
        .option("name", nil, ACON::Input::Option::Value[:required], "what must happen, e.g. \"Tavern responds to the notice\"")
        .option("due", "d", ACON::Input::Option::Value[:required], "due date, YYYY-MM-DD")
        .option("notes", nil, ACON::Input::Option::Value[:required], "notes, e.g. \"14 days from the notice of Sep 2\"")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      name = input.option("name").to_s
      due = input.option("due").to_s
      if name.empty? || due.empty?
        output.puts "error: --name and --due are required"
        return ACON::Command::Status::FAILURE
      end

      deadline = {"name" => name, "due_on" => due}
      if notes = input.option("notes").to_s.presence
        deadline["notes"] = notes
      end
      result = Api.post("/api/v1/matters/#{Api.path_segment(input.argument("matter").to_s)}/deadlines", {deadline: deadline})
      if json?(input)
        output.puts result.to_pretty_json
      else
        output.puts DeadlineText.line(result["deadline"])
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "deadlines:add failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  # deadlines:done and deadlines:reopen share everything but the action.
  abstract class DeadlineActionCommand < ACON::Command
    include JSONOption

    abstract def action : String

    protected def configure : Nil
      self.class.add_json_option(self)
      self
        .argument("matter", :required, "matter number or ID")
        .argument("deadline", :required, "deadline ID (see `rightdocuments deadlines MATTER`)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      matter = Api.path_segment(input.argument("matter").to_s)
      deadline = Api.path_segment(input.argument("deadline").to_s)
      result = Api.request("POST", "/api/v1/matters/#{matter}/deadlines/#{deadline}/#{action}")
      if json?(input)
        output.puts result.to_pretty_json
      else
        output.puts DeadlineText.line(result["deadline"])
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "deadlines:#{action} failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deadlines:done", description: "Mark a deadline done")]
  class DeadlinesDoneCommand < DeadlineActionCommand
    def action : String
      "complete"
    end
  end

  @[ACONA::AsCommand("deadlines:reopen", description: "Reopen a done deadline")]
  class DeadlinesReopenCommand < DeadlineActionCommand
    def action : String
      "reopen"
    end
  end

  @[ACONA::AsCommand("deadlines:remove", description: "Remove a deadline")]
  class DeadlinesRemoveCommand < ACON::Command
    protected def configure : Nil
      self
        .argument("matter", :required, "matter number or ID")
        .argument("deadline", :required, "deadline ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      matter = Api.path_segment(input.argument("matter").to_s)
      deadline = Api.path_segment(input.argument("deadline").to_s)
      Api.delete("/api/v1/matters/#{matter}/deadlines/#{deadline}")
      output.puts "Removed."
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "deadlines:remove failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end
end
