# Void and restore. A voided document is hidden from lists and checklists;
# only an admin can delete it permanently, and only after it is voided.
module RightDocuments
  @[ACONA::AsCommand("documents:void", description: "Void a document (hide it; restore later, or delete permanently)")]
  class DocumentsVoidCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DocumentsVoidCommand.add_json_option(self)
      self.argument("id", :required, "document ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      result = Api.request("POST", "/api/v1/documents/#{Api.path_segment(input.argument("id").to_s)}/void")
      if json?(input)
        output.puts result.to_pretty_json
      else
        output.puts "voided #{MatterText.s(result.dig?("document", "id"))} (#{MatterText.s(result.dig?("document", "voided_at"))})"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "documents:void failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("documents:restore", description: "Restore a voided document")]
  class DocumentsRestoreCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DocumentsRestoreCommand.add_json_option(self)
      self.argument("id", :required, "document ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      result = Api.request("POST", "/api/v1/documents/#{Api.path_segment(input.argument("id").to_s)}/restore")
      if json?(input)
        output.puts result.to_pretty_json
      else
        output.puts "restored #{MatterText.s(result.dig?("document", "id"))}"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "documents:restore failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end
end
