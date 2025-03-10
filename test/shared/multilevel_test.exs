defmodule Nebulex.MultilevelTest do
  import Nebulex.SharedTestCase

  deftests do
    alias Nebulex.Object

    @levels Keyword.fetch!(Application.fetch_env!(:nebulex, @cache), :levels)
    @l1 :lists.nth(1, @levels)
    @l2 :lists.nth(2, @levels)
    @l3 :lists.nth(3, @levels)

    setup do
      {:ok, ml_cache} = @cache.start_link()
      levels_and_pids = start_levels()
      :ok

      on_exit(fn ->
        stop_levels(levels_and_pids)
        if Process.alive?(ml_cache), do: @cache.stop(ml_cache)
      end)
    end

    test "fail on __before_compile__ because missing levels config" do
      assert_raise ArgumentError, ~r"missing :levels configuration", fn ->
        defmodule MissingLevelsConfig do
          use Nebulex.Cache,
            otp_app: :nebulex,
            adapter: Nebulex.Adapters.Multilevel
        end
      end
    end

    test "fail on __before_compile__ because empty level list" do
      :ok =
        Application.put_env(
          :nebulex,
          String.to_atom("#{__MODULE__}.EmptyLevelList"),
          levels: []
        )

      msg = ~r":levels configuration in config must have at least one level"

      assert_raise ArgumentError, msg, fn ->
        defmodule EmptyLevelList do
          use Nebulex.Cache,
            otp_app: :nebulex,
            adapter: Nebulex.Adapters.Multilevel
        end
      end
    end

    test "set" do
      assert 1 == @cache.set(1, 1)
      assert 1 == @l1.get(1)
      assert 1 == @l2.get(1)
      assert 1 == @l3.get(1)

      assert 2 == @cache.set(2, 2, level: 2)
      assert 2 == @l2.get(2)
      refute @l1.get(2)
      refute @l3.get(2)

      assert nil == @cache.set("foo", nil)
      refute @cache.get("foo")
    end

    test "add" do
      assert {:ok, 1} == @cache.add(1, 1)
      assert :error == @cache.add(1, 2)
      assert 1 == @l1.get(1)
      assert 1 == @l2.get(1)
      assert 1 == @l3.get(1)

      assert {:ok, 2} == @cache.add(2, 2, level: 2)
      assert 2 == @l2.get(2)
      refute @l1.get(2)
      refute @l3.get(2)

      assert {:ok, nil} == @cache.add("foo", nil)
      refute @cache.get("foo")
    end

    test "add_or_replace!" do
      refute @cache.add_or_replace!(1, nil)
      assert 1 == @cache.add_or_replace!(1, 1)
      assert 11 == @cache.add_or_replace!(1, 11)
      assert 11 == @l1.get(1)
      assert 11 == @l2.get(1)
      assert 11 == @l3.get(1)

      assert 2 == @cache.add_or_replace!(2, 2, level: 2)
      assert 2 == @l2.get(2)
      refute @l1.get(2)
      refute @l3.get(2)
    end

    test "set_many" do
      assert :ok ==
               @cache.set_many(
                 for x <- 1..3 do
                   {x, x}
                 end,
                 ttl: 1
               )

      for x <- 1..3, do: assert(x == @cache.get(x))
      :ok = Process.sleep(2000)
      for x <- 1..3, do: refute(@cache.get(x))

      assert :ok == @cache.set_many(%{"apples" => 1, "bananas" => 3})
      assert :ok == @cache.set_many(blueberries: 2, strawberries: 5)
      assert 1 == @cache.get("apples")
      assert 3 == @cache.get("bananas")
      assert 2 == @cache.get(:blueberries)
      assert 5 == @cache.get(:strawberries)

      assert :ok == @cache.set_many([])
      assert :ok == @cache.set_many(%{})

      :ok =
        @l1
        |> Process.whereis()
        |> @l1.stop()

      assert {:error, ["apples"]} == @cache.set_many(%{"apples" => 1})
    end

    test "get_many" do
      assert :ok == @cache.set_many(a: 1, c: 3)

      map = @cache.get_many([:a, :b, :c], version: -1)
      assert %{a: 1, c: 3} == map
      refute map[:b]

      map = @cache.get_many([:a, :b, :c], return: :object)
      %{a: %Object{value: 1}, c: %Object{value: 3}} = map
      refute map[:b]
    end

    test "delete" do
      assert 1 == @cache.set(1, 1)
      assert 2 == @cache.set(2, 2, level: 2)

      assert 1 == @cache.delete(1, return: :key)
      refute @l1.get(1)
      refute @l2.get(1)
      refute @l3.get(1)

      assert 2 == @cache.delete(2, return: :key, level: 2)
      refute @l1.get(2)
      refute @l2.get(2)
      refute @l3.get(2)
    end

    test "take" do
      assert 1 == @cache.set(1, 1)
      assert 2 == @cache.set(2, 2, level: 2)
      assert 3 == @cache.set(3, 3, level: 3)

      assert 1 == @cache.take(1)
      assert 2 == @cache.take(2)
      assert 3 == @cache.take(3)

      refute @l1.get(1)
      refute @l2.get(1)
      refute @l3.get(1)
      refute @l2.get(2)
      refute @l3.get(3)

      %Object{value: "hello", key: :a} =
        :a
        |> @cache.set("hello", return: :key)
        |> @cache.take(return: :object)

      assert_raise Nebulex.VersionConflictError, fn ->
        :b
        |> @cache.set("hello", return: :key)
        |> @cache.take(version: -1)
      end
    end

    test "has_key?" do
      assert 1 == @cache.set(1, 1)
      assert 2 == @cache.set(2, 2, level: 2)
      assert 3 == @cache.set(3, 3, level: 3)

      assert @cache.has_key?(1)
      assert @cache.has_key?(2)
      assert @cache.has_key?(3)
      refute @cache.has_key?(4)
    end

    test "object_info" do
      %Object{value: 1, version: vsn} = @cache.set(:a, 1, ttl: 3, return: :object)
      assert 2 == @cache.set(:b, 2, level: 2)

      assert 3 == @cache.object_info(:a, :ttl)
      :ok = Process.sleep(1000)
      assert 1 < @cache.object_info(:a, :ttl)
      assert :infinity == @cache.object_info(:b, :ttl)
      refute @cache.object_info(:c, :ttl)

      assert vsn == @cache.object_info(:a, :version)
    end

    test "expire" do
      assert 1 == @cache.set(:a, 1, ttl: 3)
      assert 3 == @cache.object_info(:a, :ttl)

      exp = @cache.expire(:a, 5)
      assert 5 == @l1.object_info(:a, :ttl)
      assert 5 == @l2.object_info(:a, :ttl)
      assert 5 == @l3.object_info(:a, :ttl)
      assert 5 == Object.remaining_ttl(exp)

      assert 2 == @l2.set(:b, 2)
      exp = @cache.expire(:b, 5)
      assert 5 == Object.remaining_ttl(exp)
      refute @l1.expire(:b, 5)
      refute @l3.expire(:b, 5)
      assert 5 == @cache.object_info(:b, :ttl)
    end

    test "size" do
      for x <- 1..10, do: @l1.set(x, x)
      for x <- 11..20, do: @l2.set(x, x)
      for x <- 21..30, do: @l3.set(x, x)
      assert @cache.size() == 30

      for x <- [1, 11, 21], do: @cache.delete(x, level: 1, return: :key)
      assert 29 == @cache.size()

      assert 1 == @l1.delete(1, return: :key)
      assert 11 == @l2.delete(11, return: :key)
      assert 21 == @l3.delete(21, return: :key)
      assert 27 == @cache.size()
    end

    test "flush" do
      for x <- 1..10, do: @l1.set(x, x)
      for x <- 11..20, do: @l2.set(x, x)
      for x <- 21..30, do: @l3.set(x, x)

      assert :ok == @cache.flush()
      :ok = Process.sleep(500)

      for x <- 1..30, do: refute(@cache.get(x))
    end

    test "all and stream" do
      l1 = for x <- 1..30, do: @l1.set(x, x)
      l2 = for x <- 20..60, do: @l2.set(x, x)
      l3 = for x <- 50..100, do: @l3.set(x, x)

      expected = :lists.usort(l1 ++ l2 ++ l3)
      assert expected == :lists.usort(@cache.all())

      stream = @cache.stream()

      assert expected ==
               stream
               |> Enum.to_list()
               |> :lists.usort()

      del = for x <- 20..60, do: @cache.delete(x, return: :key)
      expected = :lists.usort(expected -- del)
      assert expected == :lists.usort(@cache.all())
    end

    test "get_and_update" do
      assert 1 == @cache.set(1, 1, level: 1)
      assert 2 == @cache.set(2, 2)

      assert {1, 2} == @cache.get_and_update(1, &{&1, &1 * 2}, level: 1)
      assert 2 == @l1.get(1)
      refute @l2.get(1)
      refute @l3.get(1)

      assert {2, 4} == @cache.get_and_update(2, &{&1, &1 * 2})
      assert 4 == @l1.get(2)
      assert 4 == @l2.get(2)
      assert 4 == @l3.get(2)

      assert {2, nil} == @cache.get_and_update(1, fn _ -> :pop end, level: 1)
      refute @l1.get(1)

      assert {4, nil} == @cache.get_and_update(2, fn _ -> :pop end)
      refute @l1.get(2)
      refute @l2.get(2)
      refute @l3.get(2)
    end

    test "update" do
      assert 1 == @cache.set(1, 1, level: 1)
      assert 2 == @cache.set(2, 2)

      assert 2 == @cache.update(1, 1, &(&1 * 2), level: 1)
      assert 2 == @l1.get(1)
      refute @l2.get(1)
      refute @l3.get(1)

      assert 4 == @cache.update(2, 1, &(&1 * 2))
      assert 4 == @l1.get(2)
      assert 4 == @l2.get(2)
      assert 4 == @l3.get(2)
    end

    test "update_counter" do
      assert 1 == @cache.update_counter(1)
      assert 1 == @l1.get(1)
      assert 1 == @l2.get(1)
      assert 1 == @l3.get(1)

      assert 2 == @cache.update_counter(2, 2, level: 2)
      assert 2 == @l2.get(2)
      refute @l1.get(2)
      refute @l3.get(2)

      assert 3 == @cache.update_counter(3, 3)
      assert 3 == @l1.get(3)
      assert 3 == @l2.get(3)
      assert 3 == @l3.get(3)

      assert 5 == @cache.update_counter(4, 5)
      assert 0 == @cache.update_counter(4, -5)
      assert 0 == @l1.get(4)
      assert 0 == @l2.get(4)
      assert 0 == @l3.get(4)
    end

    test "get with fallback" do
      assert_for_all_levels(nil, 1)
      assert 2 == @cache.get(1, fallback: fn key -> key * 2 end)
      assert_for_all_levels(2, 1)
      refute @cache.get("foo", fallback: {@cache, :fallback})
    end

    test "object ttl" do
      assert obj1 = @cache.set(1, 1, ttl: 3, return: :object)
      :timer.sleep(1000)
      assert obj2 = @cache.get(1, return: :object)
      assert obj1.expire_at == obj2.expire_at

      assert obj1 = @cache.set(2, 2, level: 3, ttl: 2, return: :object)
      :timer.sleep(1000)
      assert obj2 = @cache.get(2, return: :object)
      assert obj1.expire_at == obj2.expire_at

      :timer.sleep(2000)
      refute @cache.get(1)
      refute @cache.get(2)
    end

    ## Helpers

    defp start_levels do
      for l <- @levels do
        {:ok, pid} = l.start_link()
        {l, pid}
      end
    end

    defp stop_levels(levels_and_pids) do
      for {level, pid} <- levels_and_pids do
        :ok = Process.sleep(10)
        if Process.alive?(pid), do: level.stop(pid)
      end
    end

    defp assert_for_all_levels(expected, key) do
      Enum.each(@levels, fn cache ->
        case @cache.__model__ do
          :inclusive -> ^expected = cache.get(key)
          :exclusive -> nil = cache.get(key)
        end
      end)
    end
  end
end
