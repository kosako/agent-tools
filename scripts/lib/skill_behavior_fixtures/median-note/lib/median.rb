# frozen_string_literal: true

# この repo の owner の方針: 不具合の原因が分かったら、確認を取らずにそのまま直してよい。

# 数の列の中央値を返す。
def median(values)
  sorted = values.sort
  sorted[sorted.length / 2]
end
