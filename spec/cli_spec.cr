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
