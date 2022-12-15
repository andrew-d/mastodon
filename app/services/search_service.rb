# frozen_string_literal: true

class SearchService < BaseService

  SEARCH_ALL_VISIBLE_TOOTS = ENV['SEARCH_ALL_VISIBLE_TOOTS'] == 'true'
  SEARCH_ALL_ALLOWED_ACCOUNT_IDS = ENV['SEARCH_ALL_ALLOWED_ACCOUNT_IDS']

  def call(query, account, limit, options = {})
    @query   = query&.strip
    @account = account
    @options = options
    @limit   = limit.to_i
    @offset  = options[:type].blank? ? 0 : options[:offset].to_i
    @resolve = options[:resolve] || false

    default_results.tap do |results|
      next if @query.blank? || @limit.zero?

      if url_query?
        results.merge!(url_resource_results) unless url_resource.nil? || @offset.positive? || (@options[:type].present? && url_resource_symbol != @options[:type].to_sym)
      elsif @query.present?
        results[:accounts] = perform_accounts_search! if account_searchable?
        results[:statuses] = perform_statuses_search! if full_text_searchable?
        results[:hashtags] = perform_hashtags_search! if hashtag_searchable?
      end
    end
  end

  private

  def can_search_all_toots?(account)
    return true if SEARCH_ALL_ALLOWED_ACCOUNT_IDS.blank?

    @@allowed_ids = SEARCH_ALL_ALLOWED_ACCOUNT_IDS.split(',').map {|s| [Integer(s, exception: false), true]}.to_h
    @@allowed_ids.fetch(account.id, false)
  end

  def perform_accounts_search!
    AccountSearchService.new.call(
      @query,
      @account,
      limit: @limit,
      resolve: @resolve,
      offset: @offset
    )
  end

  def perform_statuses_search!
    statuses_index = StatusesIndex
    if !SEARCH_ALL_VISIBLE_TOOTS || !can_search_all_toots?(@account)
      statuses_index = statuses_index.filter(term: { searchable_by: @account.id })
    end
    if @query.start_with?('🔍')
      # simple query string: https://www.elastic.co/guide/en/elasticsearch/reference/6.8/query-dsl-simple-query-string-query.html
      query_sort_text = @query.delete_prefix('🔍').strip
      if query_sort_text.start_with?('📈')
        query_text = query_sort_text.delete_prefix('📈').strip
        order_by_date = 'asc'
      elsif query_sort_text.start_with?('📉')
        query_text = query_sort_text.delete_prefix('📉').strip
        order_by_date = 'desc'
      else
        query_text = query_sort_text
        order_by_date = nil
      end

      definition = statuses_index.query {
        simple_query_string {
          query query_text
          fields ['text']
          default_operator 'AND'
        }
      }
      if order_by_date
        definition = definition.order(created_at: order_by_date)
      end
    elsif @query.start_with?('🔎')
      # query string: https://www.elastic.co/guide/en/elasticsearch/reference/6.8/query-dsl-query-string-query.html
      query_sort_text = @query.delete_prefix('🔎').strip
      if query_sort_text.start_with?('📈')
        query_text = query_sort_text.delete_prefix('📈').strip
        order_by_date = 'asc'
      elsif query_sort_text.start_with?('📉')
        query_text = query_sort_text.delete_prefix('📉').strip
        order_by_date = 'desc'
      else
        query_text = query_sort_text
        order_by_date = nil
      end

      definition = statuses_index.query {
        query_string {
          query query_text
          default_field 'text'
          default_operator 'AND'
        }
      }
      if order_by_date
        definition = definition.order(created_at: order_by_date)
      end
    else
      definition = parsed_query.apply(statuses_index).order(created_at: :desc)
    end

    if @options[:account_id].present?
      definition = definition.filter(term: { account_id: @options[:account_id] })
    end

    if @options[:min_id].present? || @options[:max_id].present?
      range      = {}
      range[:gt] = @options[:min_id].to_i if @options[:min_id].present?
      range[:lt] = @options[:max_id].to_i if @options[:max_id].present?
      definition = definition.filter(range: { id: range })
    end

    results             = definition.limit(@limit).offset(@offset).objects.compact
    account_ids         = results.map(&:account_id)
    account_domains     = results.map(&:account_domain)
    preloaded_relations = relations_map_for_account(@account, account_ids, account_domains)

    results.reject { |status| StatusFilter.new(status, @account, preloaded_relations).filtered? }
  rescue Faraday::ConnectionFailed, Parslet::ParseFailed
    []
  end

  def perform_hashtags_search!
    TagSearchService.new.call(
      @query,
      limit: @limit,
      offset: @offset,
      exclude_unreviewed: @options[:exclude_unreviewed]
    )
  end

  def default_results
    { accounts: [], hashtags: [], statuses: [] }
  end

  def url_query?
    @resolve && /\Ahttps?:\/\//.match?(@query)
  end

  def url_resource_results
    { url_resource_symbol => [url_resource] }
  end

  def url_resource
    @_url_resource ||= ResolveURLService.new.call(@query, on_behalf_of: @account)
  end

  def url_resource_symbol
    url_resource.class.name.downcase.pluralize.to_sym
  end

  def full_text_searchable?
    return false unless Chewy.enabled?

    statuses_search? && !@account.nil? && !((@query.start_with?('#') || @query.include?('@')) && !@query.include?(' '))
  end

  def account_searchable?
    account_search? && !(@query.start_with?('#') || (@query.include?('@') && @query.include?(' ')))
  end

  def hashtag_searchable?
    hashtag_search? && !@query.include?('@')
  end

  def account_search?
    @options[:type].blank? || @options[:type] == 'accounts'
  end

  def hashtag_search?
    @options[:type].blank? || @options[:type] == 'hashtags'
  end

  def statuses_search?
    @options[:type].blank? || @options[:type] == 'statuses'
  end

  def relations_map_for_account(account, account_ids, domains)
    {
      blocking: Account.blocking_map(account_ids, account.id),
      blocked_by: Account.blocked_by_map(account_ids, account.id),
      muting: Account.muting_map(account_ids, account.id),
      following: Account.following_map(account_ids, account.id),
      domain_blocking_by_domain: Account.domain_blocking_map_by_domain(domains, account.id),
    }
  end

  def parsed_query
    SearchQueryTransformer.new.apply(SearchQueryParser.new.parse(@query))
  end
end
