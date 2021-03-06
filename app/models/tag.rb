class Tag < ApplicationRecord
  has_one :wiki_page, :foreign_key => "title", :primary_key => "name"
  has_one :artist, :foreign_key => "name", :primary_key => "name"
  has_one :antecedent_alias, -> {active}, :class_name => "TagAlias", :foreign_key => "antecedent_name", :primary_key => "name"
  has_many :consequent_aliases, -> {active}, :class_name => "TagAlias", :foreign_key => "consequent_name", :primary_key => "name"
  has_many :antecedent_implications, -> {active}, :class_name => "TagImplication", :foreign_key => "antecedent_name", :primary_key => "name"
  has_many :consequent_implications, -> {active}, :class_name => "TagImplication", :foreign_key => "consequent_name", :primary_key => "name"

  validates :name, tag_name: true, uniqueness: true, on: :create
  validates :name, tag_name: true, on: :name
  validates_inclusion_of :category, in: TagCategory.category_ids

  before_save :update_category_cache, if: :category_changed?
  before_save :update_category_post_counts, if: :category_changed?

  scope :empty, -> { where("tags.post_count <= 0") }
  scope :nonempty, -> { where("tags.post_count > 0") }

  module ApiMethods
    def to_legacy_json
      return {
        "name" => name,
        "id" => id,
        "created_at" => created_at.try(:strftime, "%Y-%m-%d %H:%M"),
        "count" => post_count,
        "type" => category,
        "ambiguous" => false
      }.to_json
    end
  end

  class CategoryMapping
    TagCategory.reverse_mapping.each do |value, category|
      define_method(category) do
        value
      end
    end

    def regexp
      @regexp ||= Regexp.compile(TagCategory.mapping.keys.sort_by {|x| -x.size}.join("|"))
    end

    def value_for(string)
      norm_string = string.to_s.downcase
      if norm_string =~ /\A#{TagCategory.category_ids_regex}\z/
        norm_string.to_i
      elsif TagCategory.mapping[string.to_s.downcase]
        TagCategory.mapping[string.to_s.downcase]
      else
        0
      end
    end
  end

  module CountMethods
    extend ActiveSupport::Concern

    module ClassMethods
      # Lock the tags first in alphabetical order to avoid deadlocks under concurrent updates.
      #
      # https://stackoverflow.com/questions/44660368/postgres-update-with-order-by-how-to-do-it
      # https://www.postgresql.org/message-id/flat/freemail.20070030161126.43285%40fm10.freemail.hu
      # https://www.postgresql.org/message-id/flat/CAKOSWNkb3Zy_YFQzwyRw3MRrU10LrMj04%2BHdByfQu6M1S5B7mg%40mail.gmail.com#9dc514507357472bdf22d3109d9c7957
      def increment_post_counts(tag_names)
        Tag.where(name: tag_names).order(:name).lock("FOR UPDATE").pluck(1)
        Tag.where(name: tag_names).update_all("post_count = post_count + 1")
      end

      def decrement_post_counts(tag_names)
        Tag.where(name: tag_names).order(:name).lock("FOR UPDATE").pluck(1)
        Tag.where(name: tag_names).update_all("post_count = post_count - 1")
      end

      # fix tags where the post count is non-zero but the tag isn't present on any posts.
      def regenerate_nonexistent_post_counts!
        Tag.find_by_sql(<<~SQL)
          UPDATE tags
          SET post_count = 0
          WHERE
            post_count != 0
            AND name NOT IN (
              SELECT DISTINCT tag
              FROM posts, unnest(string_to_array(tag_string, ' ')) AS tag
              GROUP BY tag
            )
          RETURNING tags.*
        SQL
      end

      # fix tags where the stored post count doesn't match the true post count.
      def regenerate_incorrect_post_counts!
        Tag.find_by_sql(<<~SQL)
          UPDATE tags
          SET post_count = true_count
          FROM (
            SELECT tag, COUNT(*) AS true_count
            FROM posts, unnest(string_to_array(tag_string, ' ')) AS tag
            GROUP BY tag
          ) true_counts
          WHERE
            tags.name = tag AND tags.post_count != true_count
          RETURNING tags.*
        SQL
      end

      def regenerate_post_counts!
        tags = []
        tags += regenerate_incorrect_post_counts!
        tags += regenerate_nonexistent_post_counts!
        tags
      end
    end
  end

  module CategoryMethods
    module ClassMethods
      def categories
        @categories ||= CategoryMapping.new
      end

      def select_category_for(tag_name)
        Tag.where(name: tag_name).pick(:category).to_i
      end

      def category_for(tag_name, options = {})
        return Tag.categories.general if tag_name.blank?

        if options[:disable_caching]
          select_category_for(tag_name)
        else
          Cache.get("tc:#{Cache.hash(tag_name)}") do
            select_category_for(tag_name)
          end
        end
      end

      def categories_for(tag_names, options = {})
        if options[:disable_caching]
          Array(tag_names).inject({}) do |hash, tag_name|
            hash[tag_name] = select_category_for(tag_name)
            hash
          end
        else
          Cache.get_multi(Array(tag_names), "tc") do |tag|
            Tag.select_category_for(tag)
          end
        end
      end
    end

    def self.included(m)
      m.extend(ClassMethods)
    end

    def category_name
      TagCategory.reverse_mapping[category].capitalize
    end

    def update_category_post_counts
      Post.with_timeout(30_000, nil, :tags => name) do
        Post.raw_tag_match(name).where("true /* Tag#update_category_post_counts */").find_each do |post|
          post.reload
          post.set_tag_counts(false)
          args = TagCategory.categories.map {|x| ["tag_count_#{x}", post.send("tag_count_#{x}")]}.to_h.update(:tag_count => post.tag_count)
          Post.where(:id => post.id).update_all(args)
        end
      end
    end

    def update_category_cache
      Cache.put("tc:#{Cache.hash(name)}", category, 3.hours)
    end
  end

  concerning :NameMethods do
    def pretty_name
      name.tr("_", " ")
    end

    def unqualified_name
      name.gsub(/_\(.*\)\z/, "").tr("_", " ")
    end

    class_methods do
      def normalize_name(name)
        name.to_s.mb_chars.downcase.strip.tr(" ", "_").to_s
      end

      def create_for_list(names)
        names.map {|x| find_or_create_by_name(x).name}
      end

      def find_or_create_by_name(name, creator: CurrentUser.user)
        name = normalize_name(name)
        category = nil

        if name =~ /\A(#{categories.regexp}):(.+)\Z/
          category = $1
          name = $2
        end

        tag = find_by_name(name)

        if tag
          if category
            category_id = categories.value_for(category)

            # in case a category change hasn't propagated to this server yet,
            # force an update the local cache. This may get overwritten in the
            # next few lines if the category is changed.
            tag.update_category_cache

            if Pundit.policy!([creator, nil], tag).can_change_category?
              tag.update(category: category_id)
            end
          end

          tag
        else
          Tag.new.tap do |t|
            t.name = name
            t.category = categories.value_for(category)
            t.save
          end
        end
      end
    end
  end

  module ParseMethods
    # true if query is a single "simple" tag (not a metatag, negated tag, or wildcard tag).
    def is_simple_tag?(query)
      is_single_tag?(query) && !is_metatag?(query) && !is_negated_tag?(query) && !is_optional_tag?(query) && !is_wildcard_tag?(query)
    end

    def is_single_tag?(query)
      PostQueryBuilder.scan_query(query).size == 1
    end

    def is_metatag?(tag)
      has_metatag?(tag, *PostQueryBuilder::METATAGS)
    end

    def is_negated_tag?(tag)
      tag.starts_with?("-")
    end

    def is_optional_tag?(tag)
      tag.starts_with?("~")
    end

    def is_wildcard_tag?(tag)
      tag.include?("*")
    end

    def has_metatag?(tags, *metatags)
      return nil if tags.blank?

      tags = PostQueryBuilder.scan_query(tags.to_str) if tags.respond_to?(:to_str)
      tags.grep(/\A(?:#{metatags.map(&:to_s).join("|")}):(.+)\z/i) { $1 }.first
    end
  end

  module SearchMethods
    # ref: https://www.postgresql.org/docs/current/static/pgtrgm.html#idm46428634524336
    def order_similarity(name)
      # trunc(3 * sim) reduces the similarity score from a range of 0.0 -> 1.0 to just 0, 1, or 2.
      # This groups tags first by approximate similarity, then by largest tags within groups of similar tags.
      order(Arel.sql("trunc(3 * similarity(name, #{connection.quote(name)})) DESC"), "post_count DESC", "name DESC")
    end

    # ref: https://www.postgresql.org/docs/current/static/pgtrgm.html#idm46428634524336
    def fuzzy_name_matches(name)
      where("tags.name % ?", name)
    end

    def name_matches(name)
      where_like(:name, normalize_name(name))
    end

    def alias_matches(name)
      where(name: TagAlias.active.where_ilike(:antecedent_name, normalize_name(name)).select(:consequent_name))
    end

    def name_or_alias_matches(name)
      name_matches(name).or(alias_matches(name))
    end

    def wildcard_matches(tag, limit: 25)
      nonempty.name_matches(tag).order(post_count: :desc, name: :asc).limit(limit).pluck(:name)
    end

    def search(params)
      q = super

      q = q.search_attributes(params, :is_locked, :category, :post_count, :name)

      if params[:fuzzy_name_matches].present?
        q = q.fuzzy_name_matches(params[:fuzzy_name_matches])
      end

      if params[:name_matches].present?
        q = q.name_matches(params[:name_matches])
      end

      if params[:name_normalize].present?
        q = q.where("tags.name": normalize_name(params[:name_normalize]).split(","))
      end

      if params[:name_or_alias_matches].present?
        q = q.name_or_alias_matches(params[:name_or_alias_matches])
      end

      if params[:hide_empty].to_s.truthy?
        q = q.nonempty
      end

      if params[:has_wiki].to_s.truthy?
        q = q.joins(:wiki_page).merge(WikiPage.undeleted)
      elsif params[:has_wiki].to_s.falsy?
        q = q.left_outer_joins(:wiki_page).where("wiki_pages.title IS NULL OR wiki_pages.is_deleted = TRUE")
      end

      if params[:has_artist].to_s.truthy?
        q = q.joins(:artist).merge(Artist.undeleted)
      elsif params[:has_artist].to_s.falsy?
        q = q.left_outer_joins(:artist).where("artists.name IS NULL OR artists.is_deleted = TRUE")
      end

      case params[:order]
      when "name"
        q = q.order("name")
      when "date"
        q = q.order("id desc")
      when "count"
        q = q.order("post_count desc")
      when "similarity"
        q = q.order_similarity(params[:fuzzy_name_matches]) if params[:fuzzy_name_matches].present?
      else
        q = q.apply_default_order(params)
      end

      q
    end

    def names_matches_with_aliases(name, limit)
      name = normalize_name(name)
      wildcard_name = name + '*'

      query1 =
        Tag
        .nonempty
        .select("tags.name, tags.post_count, tags.category, null AS antecedent_name")
        .name_matches(wildcard_name)
        .order(post_count: :desc)
        .limit(limit)

      query2 =
        TagAlias
        .select("tags.name, tags.post_count, tags.category, tag_aliases.antecedent_name")
        .joins("INNER JOIN tags ON tags.name = tag_aliases.consequent_name")
        .where_like(:antecedent_name, wildcard_name)
        .active
        .where_not_like("tags.name", wildcard_name)
        .where("tags.post_count > 0")
        .order("tags.post_count desc")
        .limit(limit * 2) # Get extra records in case some duplicates get filtered out.

      sql_query = "((#{query1.to_sql}) UNION ALL (#{query2.to_sql})) AS unioned_query"
      tags = Tag.select("DISTINCT ON (name, post_count) *").from(sql_query).order("post_count desc").limit(limit)

      if tags.empty?
        tags = Tag.select("tags.name, tags.post_count, tags.category, null AS antecedent_name").fuzzy_name_matches(name).order_similarity(name).nonempty.limit(limit)
      end

      tags
    end
  end

  def self.convert_cosplay_tags(tags)
    cosplay_tags, other_tags = tags.partition {|tag| tag.match(/\A(.+)_\(cosplay\)\Z/) }
    cosplay_tags.grep(/\A(.+)_\(cosplay\)\Z/) { "#{TagAlias.to_aliased([$1]).first}_(cosplay)" } + other_tags
  end

  def posts
    Post.tag_match(name)
  end

  def self.available_includes
    [:wiki_page, :artist, :antecedent_alias, :consequent_aliases, :antecedent_implications, :consequent_implications]
  end

  include ApiMethods
  include CountMethods
  include CategoryMethods
  extend ParseMethods
  extend SearchMethods
end
