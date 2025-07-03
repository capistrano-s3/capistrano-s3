# frozen_string_literal: true

$LOAD_PATH.unshift(File.dirname(__FILE__) + "/lib")
require "capistrano/s3/version"

Gem::Specification.new do |s|
  s.authors = [
    "Jean-Philippe Doyle",
    "Josh Delsman",
    "Aleksandrs Ļedovskis",
    "Douglas Jarquin",
    "Amit Barvaz",
    "Jan Lindblom"
  ]
  s.email = ["jeanphilippe.doyle@hooktstudios.com", "aleksandrs@ledovskis.lv"]
  s.description =
    "Enables static websites deployment to Amazon S3 website buckets using Capistrano."
  s.summary = "Build and deploy a static website to Amazon S3"
  s.homepage = "https://github.com/capistrano-s3/capistrano-s3"
  s.licenses = ["MIT"]
  s.files = `git ls-files`.split($OUTPUT_RECORD_SEPARATOR)
  s.executables = s.files.grep(%r{^bin/}).map { |f| File.basename(f) }
  s.name = "capistrano-s3"
  s.require_paths = ["lib"]
  s.version = Capistrano::S3::VERSION
  s.cert_chain = ["certs/aleksandrs-ledovskis--2025-07-03-2035-07-01.pem"]
  s.signing_key = File.expand_path("~/.ssh/gem-private_key.pem") if $PROGRAM_NAME.end_with?("gem")

  # Min rubies
  s.required_ruby_version = ">= 2.5.0"

  # Gem dependencies
  s.add_runtime_dependency "aws-sdk",    "~> 2.6"
  s.add_runtime_dependency "capistrano", ">= 2"
  s.add_runtime_dependency "mime-types"
  s.add_runtime_dependency "webrick" # Temporary, while 'aws-sdk' is < 3.0

  s.metadata["rubygems_mfa_required"] = "true"
end
