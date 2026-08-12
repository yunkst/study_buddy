/// FSRS (Free Spaced Repetition Scheduler) 算法参数常量。
///
/// 所有常数均为 `const` 编译期常量，被 ReviewScheduler 及其上层仓储
/// （Task 1.3-1.8）消费。调参时只需修改此文件，不需要触碰算法实现。
library;

// ===== 初始稳定性 S(0)(rating 对应难度) =====

/// 评分=forgot 时的初始稳定性 S(0)=0.02（极快遗忘）。
const double kInitialSForgot = 0.02;

/// 评分=hard 时的初始稳定性 S(0)=1.0（约 1 天）。
const double kInitialSHard = 1.0;

/// 评分=good 时的初始稳定性 S(0)=3.0（约 3 天）。
const double kInitialSGood = 3.0;

/// 评分=easy 时的初始稳定性 S(0)=8.0（约 8 天）。
const double kInitialSEasy = 8.0;

// ===== 失败(lapse)时稳定性下限与衰减 =====

/// 失败后稳定性新值下限(防止 S 跌到 0 失去意义)。
const double kMinStabilityAfterLapse = 0.4;

/// 失败(lapse)时稳定性乘数(旧 S 衰减比例: S_new = S_old * 0.3)。
const double kLapseStabilityMultiplier = 0.3;

// ===== 成功时稳定性增长系数(R 增长率) =====

/// 评分=hard 时的稳定性增长系数。
const double kGrowthHard = 1.2;

/// 评分=good 时的稳定性增长系数。
const double kGrowthGood = 2.5;

/// 评分=easy 时的稳定性增长系数。
const double kGrowthEasy = 4.0;

// ===== 难度 D 调整偏移 =====

/// 评分=hard 时难度上调偏移。
const double kDifficultyHard = 0.15;

/// 评分=easy 时难度下调偏移。
const double kDifficultyEasy = -0.15;

/// 评分=forgot 时难度上调偏移。
const double kDifficultyForgot = 0.5;

// ===== 难度 D 边界 =====

/// 难度最小值。
const double kMinDifficulty = 1.0;

/// 难度最大值。
const double kMaxDifficulty = 10.0;

// ===== 失败再学间隔 =====

/// 评分=forgot 后再次复习的间隔(短间隔重学)。
const Duration kForgotInterval = Duration(minutes: 30);

// ===== 薄弱/已掌握阈值 =====

/// 薄弱知识点稳定性上限(超过此值不再是 weak)。
const double kWeakStabilityCeiling = 0.5;

/// 触发"虽 S 低但 D 极高视作薄弱"的难度阈值。
const double kMinDifficultyFloorForWeak = 8.0;

/// 已掌握稳定性下限(S >= 此值进入 mastered)。
const double kMasteredStabilityFloor = 21.0;

// ===== 学习状态区间 =====

/// 学习中稳定性下限(未知→学习的入口下限)。
const double kLearningStabilityFloor = 1.0;

/// 学习中稳定性上限(超过即脱学习进入 mastered 候选)。
const double kLearningStabilityCeiling = 21.0;

// ===== 状态机转移用的特殊值 =====

/// 未知→学习重置时使用的初始稳定性。
const double kUnknownResetStability = 0.4;

/// 稳定性阈值:S < 此值视为 weak。
const double kWeakStabilityThreshold = 1.0;

/// 稳定性阈值:S >= 此值视为 mastered。
const double kMasteredStabilityThreshold = 21.0;

// ===== 每日配额 =====

/// 每日复习上限。
const int kDailyReviewCap = 20;

/// 每日新卡上限。
const int kDailyNewCardCap = 5;
