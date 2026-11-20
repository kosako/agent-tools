# frozen_string_literal: true

# 数の列の中央値を返す。
def median(values)
  sorted = values.sort
  sorted[sorted.length / 2]
end
