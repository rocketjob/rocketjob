require_relative "../test_helper"

module Batch
  class CategoryTest < Minitest::Test
    describe RocketJob::Category::Input do
      describe "#cleanse_header!" do
        it "cleanses the header when cleanse_header is true" do
          category = RocketJob::Category::Input.new(columns: %w[Name Address\ One zip\ code])
          category.cleanse_header!
          assert_equal %w[name address_one zip_code], category.columns
        end

        it "does not cleanse the header when cleanse_header is false" do
          category = RocketJob::Category::Input.new(columns: %w[Name Address\ One zip\ code], header_cleanser: :none)
          category.cleanse_header!
          assert_equal %w[Name Address\ One zip\ code], category.columns
        end
      end

      describe "#tabular" do
        it "returns tabular for the current settings" do
          layout   = [
            {size: 1, key: :action},
            {size: 9, key: :date},
            {size: :remainder}
          ]
          category = RocketJob::Category::Input.new(
            columns:          %w[abc, def],
            format:           :fixed,
            format_options:   {layout: layout},
            allowed_columns:  %w[name address zip_code],
            required_columns: %w[name address],
            skip_unknown:     false
          )
          assert tabular = category.tabular
          assert_equal %w[abc, def], tabular.header.columns
          assert tabular.parser.is_a?(IOStreams::Tabular::Parser::Fixed), tabular.parser.class.name
          actual = tabular.parser.layout.columns.collect do |col|
            h       = {
              size: col.size == -1 ? :remainder : col.size
            }
            h[:key] = col.key if col.key
            h
          end
          assert_equal layout, actual
          assert_equal %w[name address zip_code], tabular.header.allowed_columns
          assert_equal %w[name address], tabular.header.required_columns
          assert_equal false, tabular.header.skip_unknown
        end

        it "uses the file_name when format is not set" do
          category = RocketJob::Category::Input.new(file_name: "sample.json")
          assert tabular = category.tabular
          assert tabular.parser.is_a?(IOStreams::Tabular::Parser::Json), tabular.parser.class.name
        end
      end
    end
  end
end
