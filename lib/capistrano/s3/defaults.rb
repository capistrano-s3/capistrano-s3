# frozen_string_literal: true

module Capistrano
  module S3
    module Defaults
      DEFAULTS = {
        deployment_path: "public",
        target_path: "",
        bucket_write_options: { acl: "public-read" },
        region: "us-east-1",
        assume_role: nil,
        redirect_options: {},
        only_gzip: false,
        invalidations: [],
        exclusions: []
      }.freeze

      def self.populate(context, set_method)
        DEFAULTS.each do |key, value|
          value = value.is_a?(Proc) ? value.call : value
          context.send(set_method, key, value)
        end
      end
    end
  end
end
