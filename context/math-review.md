keywords: formula,statistics,probability,monte carlo,sigmoid,logarithm,exponential decay,half-life,normalization,regression,interpolation,z-score,zscore,standard deviation,stddev,variance,distribution,likelihood,ornstein,mean reversion,gbm
# Math Review Context

**Hand-derive before implementing**: Write out the algebra on paper (or in comments) before translating to code. Verify each step — sign errors and off-by-one mistakes are the #1 source of silent math bugs.

**Sign conventions**: Confirm bullish = positive, bearish = negative (or vice versa) at every transformation boundary. A single sign flip inverts the entire signal chain.

**Dimensional consistency**: Check units at every step. Time constants (dt, half-life) must use consistent units (hours vs days vs seconds). Probability values must stay in [0, 1]. Log-odds are unbounded but should be clamped to prevent overflow.

**Edge cases**: Test with empty input, single element, zero variance, all-identical values, and extreme outliers. Division by zero (stddev=0, count=0) must be guarded.

**Discrete approximations**: When discretizing continuous formulas (e.g., exponential decay, OU process, GBM), verify the discrete step matches the intended time resolution. Off-by-one in loop bounds changes the result.

**Validate against known solutions**: For any new formula, test with inputs where the analytical answer is known. Compare numerical output to hand-calculated expected values.
