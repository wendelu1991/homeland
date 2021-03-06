require "auto-space"

CORRECT_CHARS = [
  ["［", "["],
  ["］", "]"],
  ["【", "["],
  ["】", "]"],
  ["（", "("],
  ["）", ")"]
]

class Topic < ApplicationRecord
  HIT_SCORE = 1
  REPLY_SCORE = 3

  include MarkdownBody
  include SoftDelete
  include Mentionable
  include Closeable
  include Searchable
  include MentionTopic
  include UserAvatarDelegate

  # 临时存储检测用户是否读过的结果
  attr_accessor :read_state, :admin_editing

  belongs_to :user, inverse_of: :topics, counter_cache: true
  belongs_to :team, counter_cache: true
  belongs_to :node, counter_cache: true
  belongs_to :last_reply_user, class_name: "User"
  belongs_to :last_reply, class_name: "Reply"
  has_many :replies, dependent: :destroy

  validates :user_id, :title, :body, :node_id, presence: true

  counter :hits, default: 0
  hash_key :daily_scores
  hash_key :weekly_scores
  sorted_set :daily_ranks, global: true
  sorted_set :weekly_ranks, global: true
  sorted_set :tap_times, global: true

  delegate :login, to: :user, prefix: true, allow_nil: true
  delegate :body, to: :last_reply, prefix: true, allow_nil: true

  # scopes
  scope :last_actived,       -> { order(last_active_mark: :desc) }
  scope :suggest,            -> { where("suggested_at IS NOT NULL").order(suggested_at: :desc) }
  scope :without_suggest,    -> { where(suggested_at: nil) }
  scope :high_likes,         -> { order(likes_count: :desc).order(id: :desc) }
  scope :high_replies,       -> { order(replies_count: :desc).order(id: :desc) }
  scope :no_reply,           -> { where(replies_count: 0) }
  scope :popular,            -> { where("likes_count > 5") }
  scope :excellent,          -> { where("excellent >= 1") }
  scope :without_hide_nodes, -> { exclude_column_ids("node_id", Topic.topic_index_hide_node_ids) }

  scope :without_node_ids,   ->(ids) { exclude_column_ids("node_id", ids) }
  scope :without_users,      ->(ids) { exclude_column_ids("user_id", ids) }
  scope :exclude_column_ids, ->(column, ids) { ids.empty? ? all : where.not(column => ids) }

  scope :without_nodes, lambda { |node_ids|
    ids = node_ids + Topic.topic_index_hide_node_ids
    ids.uniq!
    exclude_column_ids("node_id", ids)
  }

  mapping do
    indexes :title, term_vector: :yes
    indexes :body, term_vector: :yes
  end

  def as_indexed_json(_options = {})
    {
      title: self.title,
      body: self.full_body
    }
  end

  def indexed_changed?
    saved_change_to_title? || saved_change_to_body?
  end

  def related_topics(size = 5)
    opts = {
      query: {
        more_like_this: {
          fields: [:title, :body],
          docs: [
            {
              _index: self.class.index_name,
              _type: self.class.document_type,
              _id: id
            }
          ],
          min_term_freq: 2,
          min_doc_freq: 5
        }
      },
      size: size
    }
    self.class.__elasticsearch__.search(opts).records.to_a
  end

  def self.fields_for_list
    columns = %w(body who_deleted)
    select(column_names - columns.map(&:to_s))
  end

  def full_body
    ([self.body] + self.replies.pluck(:body)).join('\n\n')
  end

  def self.topic_index_hide_node_ids
    Setting.node_ids_hide_in_topics_index.to_s.split(",").collect(&:to_i)
  end

  def score_incr_by(action)
    return unless score = { hit: HIT_SCORE, reply: REPLY_SCORE }[action]

    time = Time.current
    daily_scores.incr(time.beginning_of_hour.to_i, score)
    weekly_scores.incr(time.beginning_of_day.to_i, score)
    tap_times[id] = time.to_i
  end

  def self.daily_rank
    sorted_topics(daily_ranks.members.reverse)
  end

  def self.weekly_rank
    sorted_topics(weekly_ranks.members.reverse)
  end

  def self.sorted_topics(sorted_ids)
    topics = find(sorted_ids)
    topics_hash = topics.each_with_object({}) { |topic, t_hash| t_hash[topic.id] = topic }
    sorted_topics = sorted_ids.map { |id| topics_hash[id.to_i] }
    Kaminari.paginate_array(sorted_topics)
  end
  private_class_method :sorted_topics

  def self.calc_daily_ranks(now = Time.current)
    find(tapped_topic_ids(1.day.ago, now)).each { |topic| topic.calc_daily_rank(now) }
  end

  def self.calc_weekly_ranks(now = Time.current)
    find(tapped_topic_ids(1.week.ago, now)).each { |topic| topic.calc_weekly_rank(now) }
  end

  def self.tapped_topic_ids(from, to)
    tap_times.rangebyscore(from.to_i, to.to_i)
  end
  private_class_method :tapped_topic_ids

  def calc_daily_rank(now)
    daily_ranks[id] = calc_score(daily_scores, day_hours(now))
  end

  def calc_weekly_rank(now)
    weekly_ranks[id] = calc_score(weekly_scores, week_days(now))
  end

  private

    def calc_score(score_object, timestamps)
      score_object.bulk_get(*timestamps).values.reverse.compact.map.with_index(1) { |e, i| e.to_i * i }.sum
    end

    def day_hours(now)
      @day_hours ||= (1..24).map { |i| (now.beginning_of_hour - i.hour).to_i.to_s }
    end

    def week_days(now)
      @week_days ||= (1..7).map { |i| (now.beginning_of_day - i.day).to_i.to_s }
    end

  public

  before_save :store_cache_fields
  def store_cache_fields
    self.node_name = node.try(:name) || ""
  end

  before_save :auto_correct_title
  def auto_correct_title
    CORRECT_CHARS.each do |chars|
      title.gsub!(chars[0], chars[1])
    end
    title.auto_space!
  end
  before_save do
    if admin_editing == true && self.node_id_changed?
      Topic.notify_topic_node_changed(id, node_id)
    end
  end

  before_create :init_last_active_mark_on_create
  def init_last_active_mark_on_create
    self.last_active_mark = Time.now.to_i
  end

  after_commit :async_create_reply_notify, on: :create
  def async_create_reply_notify
    NotifyTopicJob.perform_later(id)
  end

  def update_last_reply(reply, opts = {})
    # replied_at 用于最新回复的排序，如果帖着创建时间在一个月以前，就不再往前面顶了
    return false if reply.blank? && !opts[:force]

    self.last_active_mark = Time.now.to_i if created_at > 1.month.ago
    self.replied_at = reply.try(:created_at)
    self.replies_count = replies.without_system.count
    self.last_reply_id = reply.try(:id)
    self.last_reply_user_id = reply.try(:user_id)
    self.last_reply_user_login = reply.try(:user_login)
    # Reindex Search document
    SearchIndexer.perform_later("update", "topic", self.id)
    save
  end

  # 更新最后更新人，当最后个回帖删除的时候
  def update_deleted_last_reply(deleted_reply)
    return false if deleted_reply.blank?
    return false if last_reply_user_id != deleted_reply.user_id

    previous_reply = replies.without_system.where.not(id: deleted_reply.id).recent.first
    update_last_reply(previous_reply, force: true)
  end

  # 删除并记录删除人
  def destroy_by(user)
    return false if user.blank?
    update_attribute(:who_deleted, user.login)
    destroy
  end

  def destroy
    super
    delete_notifiaction_mentions
  end

  # 所有的回复编号
  def reply_ids
    Rails.cache.fetch([self, "reply_ids"]) do
      self.replies.order("id asc").pluck(:id)
    end
  end

  def excellent?
    excellent >= 1
  end

  def ban!(opts = {})
    transaction do
      update(lock_node: true, node_id: Node.no_point.id, admin_editing: true)
      if opts[:reason]
        Reply.create_system_event(action: "ban", topic_id: self.id, body: opts[:reason])
      end
    end
  end

  def excellent!
    transaction do
      Reply.create_system_event(action: "excellent", topic_id: self.id)
      update!(excellent: 1)
    end
  end

  def unexcellent!
    transaction do
      Reply.create_system_event(action: "unexcellent", topic_id: self.id)
      update!(excellent: 0)
    end
  end

  def floor_of_reply(reply)
    reply_index = reply_ids.index(reply.id)
    reply_index + 1
  end

  def self.notify_topic_created(topic_id)
    topic = Topic.find_by_id(topic_id)
    return unless topic && topic.user

    follower_ids = topic.user.follow_by_user_ids
    return if follower_ids.empty?

    notified_user_ids = topic.mentioned_user_ids

    # 给关注者发通知
    default_note = { notify_type: "topic", target_type: "Topic", target_id: topic.id, actor_id: topic.user_id }
    Notification.bulk_insert(set_size: 100) do |worker|
      follower_ids.each do |uid|
        # 排除同一个回复过程中已经提醒过的人
        next if notified_user_ids.include?(uid)
        # 排除回帖人
        next if uid == topic.user_id
        note = default_note.merge(user_id: uid)
        worker.add(note)
      end
    end

    true
  end

  def self.notify_topic_node_changed(topic_id, node_id)
    topic = Topic.find_by_id(topic_id)
    return if topic.blank?
    node = Node.find_by_id(node_id)
    return if node.blank?

    Notification.create notify_type: "node_changed",
                        user_id: topic.user_id,
                        target: topic,
                        second_target: node
    true
  end

  def self.total_pages
    return @total_pages if defined? @total_pages

    total_count = Rails.cache.fetch("topics/total_count", expires_in: 1.week) do
      self.unscoped.count
    end
    if total_count >= 1500
      @total_pages = 60
    end
    @total_pages
  end
end
