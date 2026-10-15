require "./rightdocuments/cli"
require "./rightdocuments/matters"
require "./rightdocuments/clients"
require "./rightdocuments/void"
require "./rightdocuments/documents"
require "./rightdocuments/deadlines"
require "./rightdocuments/deliveries"
require "./rightdocuments/court_cases"
require "./rightdocuments/submissions"

RightDocuments::CLI.run(ARGV)
