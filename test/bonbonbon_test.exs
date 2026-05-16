defmodule BonbonbonTest do
  use ExUnit.Case
  doctest Bonbonbon

  test "generates a 24-character-wide receipt with a total" do
    receipt = Bonbonbon.generate_receipt([12, 30])
    lines = String.split(receipt, "\n")

    assert Enum.all?(lines, &(String.length(&1) == 24))
    assert String.contains?(receipt, "SUMME")
    assert String.contains?(receipt, "42")
  end
end
