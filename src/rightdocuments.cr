require "./rightdocuments/cli"
require "./rightdocuments/matters"
require "./rightdocuments/clients"
require "./rightdocuments/void"
require "./rightdocuments/documents"
require "./rightdocuments/deadlines"
require "./rightdocuments/deliveries"

RightDocuments::CLI.run(ARGV)
