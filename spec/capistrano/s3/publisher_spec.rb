# frozen_string_literal: true

require "spec_helper"

describe Capistrano::S3::Publisher do
  before do
    @root = File.expand_path(__dir__)
    publish_file = Capistrano::S3::Publisher::LAST_PUBLISHED_FILE
    FileUtils.rm(publish_file) if File.exist?(publish_file)
  end

  describe "::files" do
    # @todo don't test via private methods
    subject(:files) { described_class.send(:files, deployment_path, exclusions) }

    let(:deployment_path) { "spec/sample-2" }
    let(:exclusions) { [] }

    it "includes dot-prefixed/hidden directories" do
      expect(files).to include("spec/sample-2/.well-known/test.txt")
    end

    it "includes dot-prefixed/hidden files" do
      expect(files).to include("spec/sample-2/public/.htaccess")
    end
  end

  describe "publish!" do
    it "publish all files" do
      Aws::S3::Client.any_instance.expects(:put_object).times(8)
      described_class.publish!("s3.amazonaws.com", "abc", "123", nil, "mybucket.amazonaws.com",
                               "spec/sample", "", "cf123", [], [], false, {}, "staging")
    end

    it "publish only gzip files when option is enabled" do
      Aws::S3::Client.any_instance.expects(:put_object).times(4)
      described_class.publish!("s3.amazonaws.com", "abc", "123", nil, "mybucket.amazonaws.com",
                               "spec/sample", "", "cf123", [], [], true, {}, "staging")
    end

    context "with invalidations" do
      it "publish all files with invalidations" do
        Aws::S3::Client.any_instance.expects(:put_object).times(8)
        Aws::CloudFront::Client.any_instance.expects(:create_invalidation).once

        described_class.publish!("s3.amazonaws.com", "abc", "123", nil, "mybucket.amazonaws.com",
                                 "spec/sample", "", "cf123", ["*"], [], false, {}, "staging")
      end

      it "publish all files without invalidations" do
        Aws::S3::Client.any_instance.expects(:put_object).times(8)
        Aws::CloudFront::Client.any_instance.expects(:create_invalidation).never

        described_class.publish!("s3.amazonaws.com", "abc", "123", nil, "mybucket.amazonaws.com",
                                 "spec/sample", "", "cf123", [], [], false, {}, "staging")
      end
    end

    context "with exclusions" do
      it "exclude one files" do
        Aws::S3::Client.any_instance.expects(:put_object).times(7)

        exclude_paths = ["fonts/cantarell-regular-webfont.svg"]
        described_class.publish!("s3.amazonaws.com", "abc", "123", nil, "mybucket.amazonaws.com",
                                 "spec/sample", "", "cf123", [], exclude_paths, false, {},
                                 "staging")
      end

      it "exclude multiple files" do
        Aws::S3::Client.any_instance.expects(:put_object).times(6)

        exclude_paths = ["fonts/cantarell-regular-webfont.svg",
                         "fonts/cantarell-regular-webfont.svg.gz"]
        described_class.publish!("s3.amazonaws.com", "abc", "123", nil, "mybucket.amazonaws.com",
                                 "spec/sample", "", "cf123", [], exclude_paths, false, {},
                                 "staging")
      end

      it "exclude directory" do
        Aws::S3::Client.any_instance.expects(:put_object).times(0)

        exclude_paths = ["fonts/**/*"]
        described_class.publish!("s3.amazonaws.com", "abc", "123", nil, "mybucket.amazonaws.com",
                                 "spec/sample", "", "cf123", [], exclude_paths, false, {},
                                 "staging")
      end
    end

    context "with write options" do
      it "sets bucket write options to all files" do
        headers = { cache_control: "no-cache" }
        extra_options = { write: headers }

        Aws::S3::Client.any_instance.expects(:put_object).with do |options|
          contains(options, headers)
        end.times(3)
        described_class.publish!("s3.amazonaws.com", "abc", "123", nil, "mybucket.amazonaws.com",
                                 "spec/sample-write", "", "cf123", [], [], false, extra_options,
                                 "staging")
      end

      it "sets object write options to a single file" do
        headers = { cache_control: "no-cache", acl: :private }
        extra_options = {
          object_write: {
            "index.html" => headers
          }
        }

        Aws::S3::Client.any_instance.expects(:put_object).with do |options|
          options[:key] == "index.html" && contains(options, headers)
        end.once
        Aws::S3::Client.any_instance.expects(:put_object).with do |options|
          options[:key] != "index.html" && !contains(options, headers)
        end.twice
        described_class.publish!("s3.amazonaws.com", "abc", "123", nil, "mybucket.amazonaws.com",
                                 "spec/sample-write", "", "cf123", [], [], false, extra_options,
                                 "staging")
      end

      it "sets object write options to a directory" do
        asset_headers = { cache_control: "max-age=3600" }
        index_headers = { cache_control: "no-cache" }
        extra_options = {
          object_write: {
            "assets/**" => asset_headers,
            "index.html" => index_headers
          }
        }

        Aws::S3::Client.any_instance.expects(:put_object).with do |options|
          options[:key] == "index.html" && !contains(options, asset_headers) &&
            contains(options, index_headers)
        end.once
        Aws::S3::Client.any_instance.expects(:put_object).with do |options|
          options[:key] != "index.html" &&
            !contains(options, index_headers) &&
            contains(options, asset_headers)
        end.twice
        described_class.publish!("s3.amazonaws.com", "abc", "123", nil, "mybucket.amazonaws.com",
                                 "spec/sample-write", "", "cf123", [], [], false, extra_options,
                                 "staging")
      end

      it "sets object write permissions in the order of definition" do
        asset_headers = { cache_control: "max-age=3600" }
        js_headers = { cache_control: "no-cache" }
        extra_options = {
          object_write: { "assets/**" => asset_headers, "assets/script.js" => js_headers }
        }

        Aws::S3::Client.any_instance.expects(:put_object).with do |options|
          options[:key] == "assets/script.js" && !contains(options, asset_headers) &&
            contains(options, js_headers)
        end.once
        Aws::S3::Client.any_instance.expects(:put_object).with do |options|
          options[:key] == "assets/style.css" && !contains(options, js_headers) &&
            contains(options, asset_headers)
        end.once
        Aws::S3::Client.any_instance.expects(:put_object).with do |options|
          options[:key] == "index.html" && !contains(options, js_headers) &&
            !contains(options, asset_headers)
        end.once
        described_class.publish!("s3.amazonaws.com", "abc", "123", nil, "mybucket.amazonaws.com",
                                 "spec/sample-write", "", "cf123", [], [], false, extra_options,
                                 "staging")
      end

      it "overwrites object write permissions with wrong ordering" do
        js_headers = { cache_control: "no-cache" }
        asset_headers = { cache_control: "max-age=3600" }
        extra_options = {
          object_write: {
            "assets/script.js" => js_headers,
            "assets/**" => asset_headers
          }
        }

        Aws::S3::Client.any_instance.expects(:put_object).with do |options|
          options[:key] != "index.html" && !contains(options, js_headers) &&
            contains(options, asset_headers)
        end.twice
        Aws::S3::Client.any_instance.expects(:put_object).with do |options|
          options[:key] == "index.html" && !contains(options, js_headers) &&
            !contains(options, asset_headers)
        end.once
        described_class.publish!("s3.amazonaws.com", "abc", "123", nil, "mybucket.amazonaws.com",
                                 "spec/sample-write", "", "cf123", [], [], false, extra_options,
                                 "staging")
      end
    end

    context "with MIME types" do
      it "sets best match MIME type by default" do
        Aws::S3::Client.any_instance.expects(:put_object).with do |options|
          options[:content_type] == "application/javascript"
        end.once
        described_class.publish!("s3.amazonaws.com", "abc", "123", nil, "mybucket.amazonaws.com",
                                 "spec/sample-mime", "", "cf123", [], [], false, {}, "staging")
      end

      it "sets CloudFront preferred MIME type if needed" do
        extra_options = { prefer_cf_mime_types: true }

        Aws::S3::Client.any_instance.expects(:put_object).with do |options|
          options[:content_type] == "application/javascript"
        end.once
        described_class.publish!("s3.amazonaws.com", "abc", "123", nil, "mybucket.amazonaws.com",
                                 "spec/sample-mime", "", "cf123", [], [], false, extra_options,
                                 "staging")
      end
    end

    context "with assume role" do
      it "publish all files" do
        Aws::S3::Client.any_instance.expects(:put_object).times(8)
        described_class.publish!("s3.amazonaws.com", "abc", "123", 'arn:aws:iam::111222333444:role/DeployRole', "mybucket.amazonaws.com",
                                 "spec/sample", "", "", [], [], false, {}, "staging")
      end
    end

  end
end
