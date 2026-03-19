require "digest"
require "json"

module Sequenced
  class Generator
    attr_reader :record, :scope, :column, :table, :start_at, :skip

    def initialize(record, options = {})
      @record = record
      @scope = options[:scope]
      @column = options[:column].to_sym
      @start_at = options[:start_at]
      @table = record.class.table_name.to_sym
      @skip = options[:skip]
    end

    def set
      return if skip? || id_set?

      lock_sequence
      record.send(:"#{column}=", next_id)
    end

    def id_set?
      !record.send(column).nil?
    end

    def skip?
      skip && skip.call(record)
    end

    def next_id
      next_id_in_sequence.tap do |id|
        id += 1 until unique?(id)
      end
    end

    def next_id_in_sequence
      start_at = self.start_at.respond_to?(:call) ? self.start_at.call(record) : self.start_at
      return start_at unless last_record = find_last_record
      max(last_record.send(column) + 1, start_at)
    end

    def unique?(id)
      build_scope do
        rel = base_relation
        rel = rel.where.not(record.class.primary_key => record.id) if record.persisted?
        rel.where("#{table}.#{column}" => id)
      end.count == 0
    end

  private

    def lock_sequence
      return unless postgresql?

      key1, key2 = advisory_lock_keys
      record.class.connection.execute("SELECT pg_advisory_xact_lock(#{key1}, #{key2})")
    end

    def postgresql?
      defined?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) &&
        record.class.connection.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
    end

    def base_relation
      record.class.base_class.unscoped
    end

    def find_last_record
      build_scope do
        base_relation
          .where("#{table}.#{column} IS NOT NULL")
          .order("#{table}.#{column} DESC")
      end.first
    end

    def advisory_lock_keys
      Digest::SHA256.digest(lock_identity).unpack("l>l>")
    end

    def lock_identity
      JSON.generate([
        "sequenced",
        table.to_s,
        column.to_s,
        resolved_scope_pairs
      ])
    end

    def resolved_scope_pairs
      scope_columns.map do |scope_column|
        [scope_column.to_s, scope_value(scope_column)]
      end
    end

    def build_scope
      rel = yield
      scope_columns.each do |scope_column|
        if scope_column.to_s.include? "."
          accessor, column = scope_column.to_s.split(".", 2)
          table = record.class.reflections[accessor].table_name
          rel = rel.joins(accessor.to_sym).includes(accessor.to_sym).where("#{table}.#{column}" => scope_value(scope_column))
        else
          rel = rel.where(scope_column => scope_value(scope_column))
        end
      end
      rel
    end

    def scope_columns
      Array(scope).compact
    end

    def scope_value(scope_column)
      if scope_column.to_s.include? "."
        _accessor, column_name = scope_column.to_s.split(".", 2)
        record.send(column_name)
      else
        record.send(scope_column)
      end
    end

    def max(*values)
      values.to_a.max
    end
  end
end
