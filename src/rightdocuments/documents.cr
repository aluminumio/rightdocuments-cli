require "digest/md5"

# Show one document with its stored files, and download those files.
module RightDocuments
  module Api
    # Streams path into io and returns the server's Content-MD5 and the MD5 of the bytes written.
    def self.download(path : String, io : IO) : {String?, String}
      uri = URI.parse("#{BASE_URL}#{path}")
      headers = HTTP::Headers{"Authorization" => "Bearer #{RightDocuments.access_token}"}
      HTTP::Client.get(uri, headers: headers) do |response|
        unless response.status.success?
          body = response.body_io.gets_to_end
          message = (JSON.parse(body)["message"]?.try(&.as_s?) rescue nil) || body
          raise "HTTP #{response.status.code}: #{message}"
        end
        digest = Digest::MD5.new
        buffer = Bytes.new(64 * 1024)
        while (read = response.body_io.read(buffer)) > 0
          chunk = buffer[0, read]
          digest.update(chunk)
          io.write(chunk)
        end
        {response.headers["Content-MD5"]?, Base64.strict_encode(digest.final)}
      end
    end
  end

  module DocumentText
    def self.size(bytes : Int64) : String
      return "#{bytes} B" if bytes < 1024
      return "#{(bytes / 1024.0).round(0).to_i} KB" if bytes < 1024 * 1024
      "#{(bytes / 1024.0 / 1024.0).round(1)} MB"
    end

    def self.files(document : JSON::Any) : Array(JSON::Any)
      document["files"]?.try(&.as_a?) || [] of JSON::Any
    end
  end

  @[ACONA::AsCommand("documents:info", description: "Show a document and its stored files")]
  class DocumentsInfoCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DocumentsInfoCommand.add_json_option(self)
      self.argument("id", :required, "document ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      result = Api.get("/api/v1/documents/#{Api.path_segment(input.argument("id").to_s)}")
      if json?(input)
        output.puts result.to_pretty_json
        return ACON::Command::Status::SUCCESS
      end

      doc = result["document"]
      output.puts "name: #{MatterText.s(doc["name"]?)}"
      output.puts "status: #{MatterText.s(doc["status"]?)}#{doc["voided_at"]?.try(&.as_s?) ? " (voided)" : ""}"
      output.puts "source: #{MatterText.s(doc["source"]?)}"
      output.puts "template: #{MatterText.s(doc.dig?("template", "name"))}" if doc["template"]?.try(&.as_h?)
      output.puts "matter: #{MatterText.s(doc.dig?("matter", "number"))} #{MatterText.s(doc.dig?("matter", "name"))}" if doc["matter"]?.try(&.as_h?)
      output.puts "created: #{MatterText.s(doc["created_at"]?)}"
      output.puts "id: #{MatterText.s(doc["id"]?)}"
      files = DocumentText.files(doc)
      output.puts "files:#{files.empty? ? " none" : ""}"
      files.each do |file|
        kind = MatterText.s(file["kind"]?)
        asset_key = kind == "asset" ? "  (key #{MatterText.s(file["key"]?)})" : ""
        output.puts "  #{kind.ljust(12)}#{DocumentText.size(file["byte_size"]?.try(&.as_i64?) || 0_i64).rjust(8)}  " \
                    "#{MatterText.s(file["filename"]?)}#{asset_key}"
      end
      output.puts "Download with `rightdocuments documents:download #{MatterText.s(doc["id"]?)} [FILE]`." unless files.empty?
      ACON::Command::Status::SUCCESS
    rescue ex
      output.puts "documents:info failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("documents:download", description: "Download a document's stored files (checks the MD5)")]
  class DocumentsDownloadCommand < ACON::Command
    protected def configure : Nil
      self
        .argument("id", :required, "document ID")
        .argument("file", :optional, "executed, unsigned, certificate, original, or an asset key (default: executed, else unsigned)")
        .option("output", "o", ACON::Input::Option::Value[:required], "file or directory to write (default: current directory)")
        .option("stdout", nil, ACON::Input::Option::Value[:none], "write the file to standard output")
        .option("all", "a", ACON::Input::Option::Value[:none], "download every stored file into the --output directory")
        .option("force", "f", ACON::Input::Option::Value[:none], "overwrite existing files")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      doc = Api.get("/api/v1/documents/#{Api.path_segment(id)}")["document"]
      files = DocumentText.files(doc)
      raise "the document has no stored files" if files.empty?

      chosen = select_files(files, input.argument("file").to_s.presence, input.option("all", Bool))
      target = input.option("output").to_s.presence
      force = input.option("force", Bool)

      if input.option("stdout", Bool)
        raise "only one file can go to stdout" if chosen.size > 1
        server_md5, md5 = Api.download(MatterText.s(chosen.first["path"]?), STDOUT)
        verify!(server_md5, md5)
        return ACON::Command::Status::SUCCESS
      end

      chosen.each do |file|
        path = destination(file, target, chosen.size > 1)
        raise "#{path} exists; use --force to overwrite" if File.exists?(path) && !force
        save(file, path)
        output.puts "#{path}\t#{DocumentText.size(file["byte_size"]?.try(&.as_i64?) || 0_i64)}\t#{MatterText.s(file["checksum"]?)}"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "documents:download failed: #{ex.message}"
      ACON::Command::Status::FAILURE
    end

    private def select_files(files : Array(JSON::Any), key : String?, all : Bool) : Array(JSON::Any)
      return files if all
      if key
        match = files.find { |f| MatterText.s(f["key"]?) == key }
        raise "no file #{key.inspect}; this document has: #{files.map { |f| MatterText.s(f["key"]?) }.join(", ")}" unless match
        return [match]
      end
      default = files.find { |f| MatterText.s(f["key"]?) == "executed" } || files.find { |f| MatterText.s(f["key"]?) == "unsigned" } || files.first
      [default]
    end

    # A directory target (or none) keeps the server's filename. With several files,
    # the kind goes in front of each name so two files with one name do not collide.
    private def destination(file : JSON::Any, target : String?, several : Bool) : String
      name = File.basename(MatterText.s(file["filename"]?).presence || "document.pdf")
      name = "#{MatterText.s(file["key"]?)}-#{name}" if several
      dir = target || "."
      if several || Dir.exists?(dir) || target.nil? || target.ends_with?('/')
        Dir.mkdir_p(dir)
        File.join(dir, name)
      else
        target
      end
    end

    private def save(file : JSON::Any, path : String) : Nil
      partial = "#{path}.part"
      begin
        server_md5, md5 = File.open(partial, "wb") { |io| Api.download(MatterText.s(file["path"]?), io) }
        verify!(server_md5, md5)
        File.rename(partial, path)
      ensure
        File.delete(partial) if File.exists?(partial)
      end
    end

    private def verify!(server_md5 : String?, md5 : String) : Nil
      return if server_md5.nil? || server_md5 == md5
      raise "checksum mismatch (server md5 #{server_md5}, received #{md5}); the file was not saved"
    end
  end
end
