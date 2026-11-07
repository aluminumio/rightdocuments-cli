require "spec"
require "../src/rightdocuments/cli"
require "../src/rightdocuments/matters"
require "../src/rightdocuments/clients"
require "../src/rightdocuments/void"
require "../src/rightdocuments/documents"
require "../src/rightdocuments/deadlines"
require "../src/rightdocuments/deliveries"
require "../src/rightdocuments/court_cases"
require "../src/rightdocuments/submissions"
require "../src/rightdocuments/workflows"

# Like ConsoleOutput, with STDOUT and STDERR captured in memory.
private class CapturedOutput < ACON::Output::IO
  include ACON::Output::ConsoleOutputInterface

  getter error_output : ACON::Output::Interface

  def initialize(stdout : ::IO, stderr : ::IO)
    super stdout, decorated: false
    @error_output = ACON::Output::IO.new(stderr, decorated: false)
  end

  def error_output=(stderr : ACON::Output::Interface) : Nil
    @error_output = stderr
  end

  def section : ACON::Output::Section
    raise "not used"
  end
end

# Runs the CLI in process without network access. Usage errors fail before a
# command executes, so no request is made.
private def run_cli(argv : Array(String)) : {Int32, String, String}
  app = RightDocuments::CLI.application
  app.auto_exit = false
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  output = CapturedOutput.new(stdout, stderr)
  status = app.run(ACON::Input::ARGV.new(argv), output)
  {app.exit_code(status), stdout.to_s, stderr.to_s}
end

describe RightDocuments::CLI do
  it "fails deadlines:remove when the deadline argument is missing" do
    code, stdout, stderr = run_cli(["deadlines:remove", "abc"])
    code.should_not eq 0
    stdout.should eq ""
    stderr.should contain "Not enough arguments (missing: 'deadline')."
    stderr.should contain "deadlines:remove <matter> <deadline>"
  end

  [
    ["deadlines:remove"],
    ["deadlines:done", "0004-001"],
    ["parties:remove", "0004-001"],
    ["matters:info"],
    ["documents:info"],
    ["submissions:info"],
  ].each do |argv|
    it "fails `#{argv.join(" ")}` with a usage error" do
      code, _, stderr = run_cli(argv)
      code.should_not eq 0
      stderr.should contain "Not enough arguments"
    end
  end

  it "fails on an unknown option" do
    code, _, stderr = run_cli(["deadlines:remove", "a", "b", "--nope"])
    code.should_not eq 0
    stderr.should contain "--nope"
  end

  it "fails on an unknown command" do
    code, _, _ = run_cli(["no-such-command"])
    code.should_not eq 0
  end

  it "exits 0 when no error is shown" do
    code, stdout, stderr = run_cli(["list"])
    code.should eq 0
    stdout.should contain "deadlines:remove"
    stderr.should eq ""
  end
end

describe "workflow commands" do
  it "fails workflows:start without --playbook before any request" do
    code, stdout, stderr = run_cli(["workflows:start", "0004-001", "--no-interaction"])
    code.should_not eq 0
    stdout.should eq ""
    stderr.should contain "--playbook is required"
  end

  [["workflows"], ["workflows:start"]].each do |argv|
    it "fails `#{argv.join(" ")}` without a matter" do
      code, _, stderr = run_cli(argv)
      code.should_not eq 0
      stderr.should contain "Not enough arguments (missing: 'matter')."
    end
  end

  it "lists the workflow commands" do
    _, stdout, _ = run_cli(["list"])
    stdout.should contain "playbooks"
    stdout.should contain "workflows:start"
  end
end

describe RightDocuments::WorkflowStart do
  it "starts a playbook that fits, or one that is not in the chooser, without asking" do
    RightDocuments::WorkflowStart.decision("fits", false, false).start?.should be_true
    RightDocuments::WorkflowStart.decision("running", false, true).start?.should be_true
    RightDocuments::WorkflowStart.decision(nil, false, false).start?.should be_true
  end

  it "asks on a terminal when the playbook may not fit" do
    RightDocuments::WorkflowStart.decision("does_not_fit", false, true).ask?.should be_true
    RightDocuments::WorkflowStart.decision("unknown", false, true).ask?.should be_true
  end

  it "refuses without --yes when it cannot ask" do
    RightDocuments::WorkflowStart.decision("does_not_fit", false, false).refuse?.should be_true
  end

  it "starts with --yes" do
    RightDocuments::WorkflowStart.decision("unknown", true, false).start?.should be_true
  end
end

describe RightDocuments::WorkflowText do
  it "shows a draft and a reviewed playbook" do
    draft = JSON.parse(%({"key": "clra-notice", "version": "0.1.0", "name": "CLRA notice", "review_status": "draft", "stub": false}))
    reviewed = JSON.parse(%({"key": "pre-suit-demand", "version": "0.2.0", "name": "Demand", "review_status": "reviewed",
      "reviewed_by": "J. Siegel", "reviewed_on": "2026-11-01", "stub": true}))
    RightDocuments::WorkflowText.review(draft).should eq "draft"
    RightDocuments::WorkflowText.review(reviewed).should eq "reviewed by J. Siegel on 2026-11-01"
    line = RightDocuments::WorkflowText.playbook_line(reviewed)
    line.should start_with "  pre-suit-demand"
    line.should contain "0.2.0"
    line.should end_with "Demand (stub)"
    named = JSON.parse(%({"key": "k", "version": "0.1.0", "name": "Discovery (stub)", "review_status": "draft", "stub": true}))
    RightDocuments::WorkflowText.playbook_line(named).should end_with "Discovery (stub)"
    RightDocuments::WorkflowText.playbook_line(named).should_not contain "(stub) (stub)"
  end

  it "shows a run with its next three open steps" do
    run = JSON.parse(%({"id": "run-1", "name": "Lawsuit · SF Superior", "playbook_key": "ca-superior-unlimited-civil",
      "playbook_version": "0.1.0", "status": "active", "started_at": "2026-11-01T10:00:00Z", "open_steps": [
        {"step_key": "a", "name": "Serve the complaint", "actor": "attorney", "status": "active", "due_on": "2026-11-20"},
        {"step_key": "b", "name": "Answer due", "actor": "counterparty", "status": "waiting", "due_on": null},
        {"step_key": "c", "name": "Cover sheet", "actor": null, "status": "active", "due_on": null},
        {"step_key": "d", "name": "Fourth", "status": "active"}]}))
    RightDocuments::WorkflowText.run_lines(run).should eq [
      "  run-1  Lawsuit · SF Superior  ca-superior-unlimited-civil@0.1.0  active  started 2026-11-01",
      "    next: Serve the complaint (attorney, due 2026-11-20)",
      "    next: Answer due (counterparty)",
      "    next: Cover sheet",
      "    (1 more open steps)",
    ]
  end

  it "shows a chooser card with its fit, court case and reasons" do
    playbook = JSON.parse(%({"key": "ca-superior-unlimited-civil", "name": "Lawsuit", "fit": "unknown",
      "fit_word": "Not enough facts to tell", "needs_court_case": true, "court_case_ids": ["case-1"],
      "reasons": [{"result": "ok", "text": "The matter is litigation."}, {"result": "unknown", "text": "Needs a court case."}]}))
    RightDocuments::WorkflowText.chooser_lines(playbook, {"case-1" => "CGC-26-612345"}).should eq [
      "  ca-superior-unlimited-civil     Not enough facts to tell    Lawsuit",
      "    case: CGC-26-612345 (case-1)",
      "    ok: The matter is litigation.",
      "    unknown: Needs a court case.",
    ]
  end

  it "says when a playbook needs a court case the matter does not have, or must choose one" do
    none = JSON.parse(%({"needs_court_case": true, "court_case_ids": []}))
    RightDocuments::WorkflowText.court_case(none, {} of String => String).should eq "needed; the matter has none (`rightdocuments cases:open`)"
    two = JSON.parse(%({"needs_court_case": true, "court_case_ids": ["a", "b"]}))
    RightDocuments::WorkflowText.court_case(two, {"a" => "CGC-1"}).should eq "one of CGC-1 (a), b (no case number yet) (pass --case)"
    RightDocuments::WorkflowText.court_case(JSON.parse(%({"needs_court_case": false})), {} of String => String).should be_nil
  end

  it "reads the reasons of a 422 body" do
    body = JSON.parse(%({"message": "Workflow not started", "fit": "unknown", "reasons": [{"result": "no", "text": "Closed."}]}))
    RightDocuments::WorkflowText.reasons(body).should eq ["no: Closed."]
    RightDocuments::WorkflowText.reasons(nil).should be_empty
  end
end
