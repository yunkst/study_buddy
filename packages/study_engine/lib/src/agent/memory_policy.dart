/// 经验记忆容量/去重规则（agent 记忆系统共用，避免场景与沉淀器两处规则漂移）。
library;

/// 记忆总容量上限（字符数）。约 2000 chars / 700 tokens。
const int kMaxMemoryChars = 2000;

/// 全部记忆条目总字符数。
int totalChars(Iterable<String> entries) =>
    entries.fold(0, (sum, e) => sum + e.length);

/// 在现有条目基础上追加 [additional] 后是否超过容量上限。
/// 恰等于上限不算超（边界含上界）。
bool isOverBudget(Iterable<String> entries,
        {Iterable<String> additional = const []}) =>
    totalChars([...entries, ...additional]) > kMaxMemoryChars;

/// 精确去重：内容是否已存在（trim 后比较，避免空白差异导致重复写入）。
bool isDuplicate(Iterable<String> entries, String content) =>
    entries.any((e) => e.trim() == content.trim());
