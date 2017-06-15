# 需求

## 一周热门
某一个 topic 的加权得分
score = ( v0 + p0 * 3 ) * 7 + (v1 + p1 * 3) * 6 + …  + (v6 + p6 * 3) * 1
v0 该 topic 今天帖子浏览数，p0 该 topic 今天的帖子回复数。
v1 昨天帖子浏览数，p1 昨天的帖子回复数，依次类推。
根据 score 由大到小排序，取前 100 为最近一周热门话题，每 1 个小时更新一次。

## 24小时热门
某一个 topic 的加权得分
score = (v0 + p0 * 3) * 24 + (v1 + p1 * 3) * 23 + … + (v23 + p23 * 3) * 1
v0 现在所在小时浏览数，p0 现在所在小时回帖数。
v1 上1个小时帖子浏览数，p1 上1个小时帖子回复数，依次类推。
根据 score 由大到小排序，取前 100 为最近 24小时热门话题，每 10 分钟更新一次。

# 实现：
话题排名功能的相关数据用 `redis` 来存储的，如下：
```ruby
    hash_key :daily_scores
    hash_key :weekly_scores
    sorted_set :daily_ranks, global: true
    sorted_set :weekly_ranks, global: true
    sorted_set :tap_times, global: true
```

1. 增加得分：每当用户浏览或创建评论时会调用 `Topic#score_incr_by` 来增加当前话题的分数`score`
    + `daily_scores` 存储`Topic`每小时的得分，键为`now.beginning_of_hour.to_i`，值为`score` 
    + `weekly_scores` 存储`Topic`每天的得分，键为`now.beginning_of_day.to_i`，值为`score`
2. 记录活跃话题：用来计算参加排名的话题，避免所有话题都参加排名计算。
    + `tap_times` 存储了`Topic` 被最后浏览或评论的时间，成员为`topic_id`，分数为`now.to_i`
3. 计算排名：定时任务会执行 `Topic.calc_weekly_ranks` 和 `Topic.calc_daily_ranks`，并将计算好的排名结果分别存放到 `daily_ranks` 和 `weekly_ranks` 中。
    + `daily_ranks` 存储了成员 `topic_id` 和他之前24小时的总分数。
    + `weekly_ranks` 存储了成员 `topic_id` 和他之前7天的总分数。
4. 获取排名：通过调用 `Topic.daily_rank` 和 `Topic.weekly_rank`。

## 模拟24小时热门总分计算方式：
- 用户点击话题，当前话题的`daily_scores`中，当前小时内加 1 分，并刷新`tap_times`中的最新时间。
- 用户回复评论，当前话题的`daily_scores`中，当前小时内加 3 分，并刷新`tap_times`中的最新时间。
- 计算排名时，选取触碰时间在 24 小时内的文章进行总分计算。
- 计算话题总分时，按照24小时从远到近顺序取出分数数组，每个分别乘以`index+1`再相加得到总分。
- 将计算的总分和`topic_id`存放到有序集合`daily_ranks`中。

## 模拟每周热门总分计算方式：
- 用户点击话题，当前话题的`weekly_scores`中，当天内加 1 分，并刷新`tap_times`中的最新时间。
- 用户回复评论，当前话题的`weekly_scores`中，当天内加 3 分，并刷新`tap_times`中的最新时间。
- 计算排名时，选取触碰时间在 7 天内的文章进行总分计算。
- 计算话题总分时，按照7天从远到近顺序取出分数数组，每个分别乘以`index+1`再相加得到总分。
- 将计算的总分和`topic_id`存放到有序集合`weekly_ranks`中。