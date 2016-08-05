alias Experimental.Flow

defmodule Flow.Window.FixedTest do
  use ExUnit.Case, async: true

  defp single_window do
    Flow.Window.fixed(1, :seconds, fn _ -> 0 end)
  end

  describe "single window" do
    test "trigger keep with large demand" do
      assert Flow.from_enumerable(1..100)
             |> Flow.partition(stages: 1)
             |> Flow.window(single_window() |> Flow.Window.trigger_every(10))
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.emit(:state)
             |> Enum.to_list() == [55, 210, 465, 820, 1275, 1830, 2485, 3240, 4095, 5050, 5050]
    end

    test "trigger keep with small demand" do
      assert Flow.from_enumerable(1..100)
             |> Flow.partition(stages: 1, max_demand: 5)
             |> Flow.window(single_window() |> Flow.Window.trigger_every(10))
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.emit(:state)
             |> Enum.to_list() == [55, 210, 465, 820, 1275, 1830, 2485, 3240, 4095, 5050, 5050]
    end

    test "trigger discard with large demand" do
      assert Flow.from_enumerable(1..100)
             |> Flow.partition(stages: 1)
             |> Flow.window(single_window() |> Flow.Window.trigger_every(10, :reset))
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.emit(:state)
             |> Enum.to_list() == [55, 155, 255, 355, 455, 555, 655, 755, 855, 955, 0]
    end

    test "trigger discard with small demand" do
      assert Flow.from_enumerable(1..100)
             |> Flow.partition(stages: 1, max_demand: 5)
             |> Flow.window(single_window() |> Flow.Window.trigger_every(10, :reset))
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.emit(:state)
             |> Enum.to_list() == [55, 155, 255, 355, 455, 555, 655, 755, 855, 955, 0]
    end

    test "trigger ordering" do
      window =
        Flow.Window.trigger(single_window(), fn -> true end, fn events, true ->
          {:cont, Enum.all?(events, &rem(&1, 2) == 0)}
        end)

      assert Flow.from_enumerable(1..10)
             |> Flow.partition(stages: 1)
             |> Flow.map(& &1 + 1)
             |> Flow.map(& &1 * 2)
             |> Flow.window(window)
             |> Flow.map(& div(&1, 2))
             |> Flow.map(& &1 + 1)
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.emit(:state)
             |> Enum.sort() == [75]
    end

    test "trigger names" do
      assert Flow.from_enumerable(1..100)
             |> Flow.partition(stages: 1)
             |> Flow.window(single_window() |> Flow.Window.trigger_every(10, :reset))
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.map_state(fn state, _, {:fixed, 0, trigger} -> {trigger, state} end)
             |> Flow.emit(:state)
             |> Enum.sort() == [{:done, 0},
                                {{:every, 10}, 55}, {{:every, 10}, 155},
                                {{:every, 10}, 255}, {{:every, 10}, 355},
                                {{:every, 10}, 455}, {{:every, 10}, 555},
                                {{:every, 10}, 655}, {{:every, 10}, 755},
                                {{:every, 10}, 855}, {{:every, 10}, 955}]
    end

    test "trigger based on intervals" do
      assert Flow.new(max_demand: 5, stages: 2)
             |> Flow.from_enumerable(Stream.concat(1..10, Stream.timer(:infinity)))
             |> Flow.partition(stages: 1, max_demand: 10)
             |> Flow.window(single_window() |> Flow.Window.trigger_periodically(10, :milliseconds))
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.map_state(& &1 * 2)
             |> Flow.emit(:state)
             |> Enum.take(1) == [110]
    end

    test "trigger based on timers" do
      assert Flow.new(max_demand: 5, stages: 2)
             |> Flow.from_enumerable(Stream.concat(1..10, Stream.timer(:infinity)))
             |> Flow.partition(stages: 1, max_demand: 10)
             |> Flow.reduce(fn ->
                  Process.send_after(self(), {:trigger, :reset, :sample}, 200)
                  0
                end, & &1 + &2)
             |> Flow.map_state(&{&1 * 2, &2, &3})
             |> Flow.emit(:state)
             |> Enum.take(1) == [{110, {0, 1}, {:global, :global, :sample}}]
    end
  end

  defp double_ordered_window do
    Flow.Window.fixed(1, :seconds, fn
      x when x <= 50 -> 0
      x when x <= 100 -> 1_000
    end)
  end

  describe "double ordered windows" do
    test "reduces per window with large demand" do
      assert Flow.from_enumerable(1..100)
             |> Flow.partition(stages: 1)
             |> Flow.window(double_ordered_window())
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.emit(:state)
             |> Enum.to_list() == [1275, 3775]
    end

    test "triggers per window with large demand" do
      assert Flow.from_enumerable(1..100)
             |> Flow.partition(stages: 1)
             |> Flow.window(double_ordered_window() |> Flow.Window.trigger_every(12))
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.map_state(fn state, _, {:fixed, fixed, trigger} -> [{state, fixed, trigger}] end)
             |> Enum.to_list() == [{78, 0, {:every, 12}},
                                   {300, 0, {:every, 12}},
                                   {666, 0, {:every, 12}},
                                   {1176, 0, {:every, 12}},
                                   {678, 1, {:every, 12}},
                                   {1500, 1, {:every, 12}},
                                   {2466, 1, {:every, 12}},
                                   {3576, 1, {:every, 12}},
                                   {1275, 0, :done},
                                   {3775, 1, :done}]
    end

    test "reduces per window with small demand" do
      assert Flow.from_enumerable(1..100)
             |> Flow.partition(stages: 1, max_demand: 5, min_demand: 0)
             |> Flow.window(double_ordered_window())
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.emit(:state)
             |> Enum.to_list() == [1275, 3775]
    end

    test "triggers per window with small demand" do
      assert Flow.from_enumerable(1..100)
             |> Flow.partition(stages: 1, max_demand: 5, min_demand: 0)
             |> Flow.window(double_ordered_window() |> Flow.Window.trigger_every(12))
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.map_state(fn state, _, {:fixed, fixed, trigger} -> [{state, fixed, trigger}] end)
             |> Enum.to_list() == [{78, 0, {:every, 12}},
                                   {300, 0, {:every, 12}},
                                   {666, 0, {:every, 12}},
                                   {1176, 0, {:every, 12}},
                                   {1275, 0, :done},
                                   {678, 1, {:every, 12}},
                                   {1500, 1, {:every, 12}},
                                   {2466, 1, {:every, 12}},
                                   {3576, 1, {:every, 12}},
                                   {3775, 1, :done}]
    end

    test "triggers for all windows" do
      assert Flow.new(max_demand: 5, stages: 1)
             |> Flow.from_enumerable(Stream.concat(1..100, Stream.timer(:infinity)))
             |> Flow.partition(stages: 1, max_demand: 5, min_demand: 0)
             |> Flow.window(double_ordered_window() |> Flow.Window.trigger_periodically(10, :milliseconds))
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.map_state(fn state, _, {:fixed, fixed, trigger} -> [{state, fixed, trigger}] end)
             |> Enum.take(2) == [{1275, 0, :done},
                                 {3381, 1, {:periodically, 10, :milliseconds}}]
    end
  end

  defp double_unordered_window_without_lateness do
    Flow.Window.fixed(1, :seconds, fn
      x when x <= 40 -> 0
      x when x <= 80 -> 2_000
      x when x <= 100 -> 0 # Those events will be lost
    end)
  end

  describe "double unordered windows without lateness" do
    test "reduces per window with large demand" do
      assert Flow.from_enumerable(1..100)
             |> Flow.partition(stages: 1)
             |> Flow.window(double_unordered_window_without_lateness())
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.emit(:state)
             |> Enum.to_list() == [2630, 0, 2420]
    end

    test "triggers per window with large demand" do
      assert Flow.from_enumerable(1..100)
             |> Flow.partition(stages: 1)
             |> Flow.window(double_unordered_window_without_lateness() |> Flow.Window.trigger_every(12))
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.map_state(fn state, _, {:fixed, fixed, trigger} -> [{state, fixed, trigger}] end)
             |> Enum.to_list() == [{78, 0, {:every, 12}},
                                   {300, 0, {:every, 12}},
                                   {666, 0, {:every, 12}},
                                   {558, 2, {:every, 12}},
                                   {1260, 2, {:every, 12}},
                                   {2106, 2, {:every, 12}},
                                   {1496, 0, {:every, 12}},
                                   {2630, 0, {:every, 12}},
                                   {2630, 0, :done},
                                   {0, 1, :done},
                                   {2420, 2, :done}]
    end

    test "reduces per window with small demand" do
      assert Flow.from_enumerable(1..100)
             |> Flow.partition(stages: 1, max_demand: 5, min_demand: 0)
             |> Flow.window(double_unordered_window_without_lateness())
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.emit(:state)
             |> Enum.to_list() == [820, 0, 2420]
    end

    test "triggers per window with small demand" do
      assert Flow.from_enumerable(1..100)
             |> Flow.partition(stages: 1, max_demand: 5, min_demand: 0)
             |> Flow.window(double_unordered_window_without_lateness() |> Flow.Window.trigger_every(12))
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.map_state(fn state, _, {:fixed, fixed, trigger} -> [{state, fixed, trigger}] end)
             |> Enum.to_list() == [{78, 0, {:every, 12}},
                                   {300, 0, {:every, 12}},
                                   {666, 0, {:every, 12}},
                                   {820, 0, :done},
                                   {0, 1, :done},
                                   {558, 2, {:every, 12}},
                                   {1260, 2, {:every, 12}},
                                   {2106, 2, {:every, 12}},
                                   {2420, 2, :done}]
    end

    test "triggers for all windows" do
      assert Flow.new(max_demand: 5, stages: 1)
             |> Flow.from_enumerable(Stream.concat(1..100, Stream.timer(:infinity)))
             |> Flow.partition(stages: 1, max_demand: 5, min_demand: 0)
             |> Flow.window(double_unordered_window_without_lateness() |> Flow.Window.trigger_periodically(10, :milliseconds))
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.map_state(fn state, _, {:fixed, fixed, trigger} -> [{state, fixed, trigger}] end)
             |> Enum.take(3) == [{820, 0, :done},
                                 {0, 1, :done},
                                 {2420, 2, {:periodically, 10, :milliseconds}}]
    end
  end
end