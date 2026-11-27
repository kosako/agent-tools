# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/median"

class MedianTest < Minitest::Test
  def test_odd_length
    assert_equal 2, median([3, 1, 2])
  end

  def test_even_length
    assert_equal 2.5, median([4, 1, 3, 2])
  end
end
