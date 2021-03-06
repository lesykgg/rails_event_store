require 'spec_helper'
require 'ruby_event_store'
require 'ruby_event_store/spec/event_repository_lint'

module RailsEventStoreActiveRecord
  module Legacy
    RSpec.describe EventRepository do
      include SchemaHelper

      def silence_stderr
        $stderr = StringIO.new
        yield
        $stderr = STDERR
      end

      around(:each) do |example|
        begin
          establish_database_connection
          load_legacy_database_schema
          silence_stderr { example.run }
        ensure
          drop_legacy_database
        end
      end

      let(:test_race_conditions_any) { !ENV['DATABASE_URL'].include?("sqlite") }
      let(:test_expected_version_auto) { false }
      let(:test_link_events_to_stream) { false }
      let(:test_binary) { false }
      let(:test_change) { false }
      let(:mapper) { RubyEventStore::Mappers::NullMapper.new }
      let(:repository) { LegacyEventRepository.new }
      let(:reader) { RubyEventStore::SpecificationReader.new(repository, mapper) }
      let(:specification) { RubyEventStore::Specification.new(reader) }

      it_behaves_like :event_repository, LegacyEventRepository

      def cleanup_concurrency_test
        ActiveRecord::Base.connection_pool.disconnect!
      end

      def verify_conncurency_assumptions
        expect(ActiveRecord::Base.connection.pool.size).to eq(5)
      end

      specify ":auto mode is not supported" do
        expect {
          repository.append_to_stream(
            RubyEventStore::SRecord.new(event_id: SecureRandom.uuid),
            'stream_2',
            RubyEventStore::ExpectedVersion.auto
          )
        }.to raise_error(RubyEventStore::InvalidExpectedVersion, ":auto mode is not supported by LegacyEventRepository")
      end

      specify "read_stream_events_forward explicit ORDER BY id" do
        expect_query(/SELECT.*FROM.*event_store_events.*WHERE.*event_store_events.*stream.*=.*ORDER BY.*event_store_events.*id.* ASC.*/) do
          repository.read(specification.stream("stream").result)
        end
      end

      specify "read_events_forward explicit ORDER BY id" do
        expect_query(/SELECT.*FROM.*event_store_events.*WHERE.*event_store_events.*stream.*=.*ORDER BY.*event_store_events.*id.* ASC LIMIT.*/) do
          repository.read(specification.stream("stream").from(:head).limit(1).result)
        end
      end

      specify "read_all_streams_forward explicit ORDER BY id" do
        expect_query(/SELECT.*FROM.*event_store_events.*ORDER BY.*event_store_events.*id.* ASC LIMIT.*/) do
          repository.read(specification.from(:head).limit(1).result)
        end
      end

      specify 'delete stream moves events back to all' do
        repository.append_to_stream(e1 = RubyEventStore::SRecord.new, RubyEventStore::Stream.new('stream'), RubyEventStore::ExpectedVersion.none)
        repository.append_to_stream(e2 = RubyEventStore::SRecord.new, RubyEventStore::Stream.new('other_stream'), RubyEventStore::ExpectedVersion.none)

        repository.delete_stream(RubyEventStore::Stream.new('stream'))
        expect(repository.read(specification.from(:head).limit(10).result).to_a).to eq([e1, e2])
        expect(repository.read(specification.stream("stream").result).to_a).to be_empty
        expect(repository.read(specification.stream("other_stream").result).to_a).to eq([e2])
      end

      specify 'active record is drunk' do
        repository.append_to_stream(e1 = RubyEventStore::SRecord.new, RubyEventStore::Stream.new('stream'), RubyEventStore::ExpectedVersion.none)
        expect_query(/UPDATE.*event_store_events.*SET.*stream.* = 'all'.*/) do
          repository.delete_stream(RubyEventStore::Stream.new('stream'))
        end
      end

      specify do
        expect {
          repository.append_to_stream(RubyEventStore::SRecord.new, RubyEventStore::Stream.new('stream_1'), RubyEventStore::ExpectedVersion.none)
          repository.append_to_stream(RubyEventStore::SRecord.new, RubyEventStore::Stream.new('stream_2'), RubyEventStore::ExpectedVersion.none)
        }.to_not raise_error
      end

      specify do
        expect {
          repository.link_to_stream(SecureRandom.uuid, RubyEventStore::Stream.new('stream_2'), RubyEventStore::ExpectedVersion.none)
        }.to raise_error(RubyEventStore::NotSupported)
      end

      it 'does not confuse all with GLOBAL_STREAM' do
        repository.append_to_stream(
          RubyEventStore::SRecord.new(event_id: "fbce0b3d-40e3-4d1d-90a1-901f1ded5a4a"),
          RubyEventStore::Stream.new('all'),
          RubyEventStore::ExpectedVersion.none
        )
        repository.append_to_stream(
          RubyEventStore::SRecord.new(event_id: "a1b49edb-7636-416f-874a-88f94b859bef"),
          RubyEventStore::Stream.new('stream'),
          RubyEventStore::ExpectedVersion.none
        )

        expect(repository.read(specification.result))
          .to(contains_ids(%w[fbce0b3d-40e3-4d1d-90a1-901f1ded5a4a a1b49edb-7636-416f-874a-88f94b859bef]))

        expect(repository.read(specification.stream('all').result))
          .to(contains_ids(%w[fbce0b3d-40e3-4d1d-90a1-901f1ded5a4a]))
      end

      specify "does not serialize to YAML twice" do
        repository.append_to_stream(
          RubyEventStore::SRecord.new(
            data:     d = YAML.dump({when: Time.now}),
            metadata: m = YAML.dump({timestamp: Time.now}),
          ),
          RubyEventStore::Stream.new('stream_1'),
          RubyEventStore::ExpectedVersion.none
        )
        row = LegacyEventRepository.const_get(:LegacyEvent).last
        expect(row.data_before_type_cast).to eq(d)
        expect(row.metadata_before_type_cast).to eq(m)
      end

      specify do
        event_1 = RubyEventStore::SRecord.new
        event_2 = RubyEventStore::SRecord.new
        event_3 = RubyEventStore::SRecord.new
        event_4 = RubyEventStore::SRecord.new
        stream_a = RubyEventStore::Stream.new('Stream A')
        stream_b = RubyEventStore::Stream.new('Stream B')
        repository.append_to_stream([event_1, event_2], stream_a, RubyEventStore::ExpectedVersion.any)
        repository.append_to_stream([event_3], stream_b, RubyEventStore::ExpectedVersion.any)

        expect(repository.streams_of(event_1.event_id)).to eq [stream_a]
        expect(repository.streams_of(event_2.event_id)).to eq [stream_a]
        expect(repository.streams_of(event_3.event_id)).to eq [stream_b]
        expect(repository.streams_of(event_4.event_id)).to eq []
      end

      private

      def expect_query(match, &block)
        count = 0
        counter_f = ->(_name, _started, _finished, _unique_id, payload) {
          count += 1 if match === payload[:sql]
        }
        ActiveSupport::Notifications.subscribed(counter_f, "sql.active_record", &block)
        expect(count).to eq(1)
      end
    end
  end
end
