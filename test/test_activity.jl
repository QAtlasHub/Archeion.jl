# activity: GitHub's contribution calendar, ported — the same table, the same attributes, the same
# quartile levels. Every assertion fixes `today`, so the page reads the same in July as in December.

# Records shaped as `build` hands them over: only the frozen time is read.
frozen_on(dates) = [(; revs=[(; entry=Dict("time" => Dict("frozen" => d))) for d in dates])]

const TODAY = Date(2026, 9, 23)                       # a Wednesday
days(html) = collect(eachmatch(r"<td[^>]*class=\"ContributionCalendar-day\"[^>]*>", html))
function levels(html)
    return [m[1] for m in eachmatch(r"data-level=\"(\d)\"[^>]*class=\"Contribution", html)]
end

@testset "activity: the table GitHub renders" begin
    html = Archeion.activity(frozen_on([DateTime(2026, 9, 21, 6)]); today=TODAY)
    @test occursin("class=\"ContributionCalendar-grid\"", html)
    @test occursin("border-spacing: 3px", html)       # 10px cells, 3px apart
    @test occursin("<caption class=\"sr-only\">Contribution Graph</caption>", html)
    @test count("<tr style=\"height: 10px\">", html) == 7     # Sunday through Saturday
    @test occursin("<tr style=\"height: 13px\">", html)       # the month label row
    # every row carries its weekday name; only Mon, Wed and Fri are left unclipped
    @test count("class=\"sr-only\">Sunday</span>", html) == 1
    @test count("clip-path: None", html) == 3
    @test count("clip-path: Circle(0)", html) == 4
    # the legend, and a swatch per level
    @test occursin("Less", html) && occursin("More", html)
    @test count("id=\"contribution-graph-legend-level-", html) == 5
end

@testset "activity: a cell per day up to today, and none after it" begin
    html = Archeion.activity(frozen_on([DateTime(2026, 9, 21, 6)]); today=TODAY)
    # 53 weeks of 7 days, less the three days of this week that have not happened
    @test length(days(html)) == 53 * 7 - 3
    @test occursin("data-date=\"2026-09-23\"", html)   # today is drawn
    @test !occursin("data-date=\"2026-09-24\"", html)  # tomorrow is not
    @test occursin("data-date=\"2025-09-21\"", html)   # 53 Sundays back
    @test occursin("1 revision on September 21st.", html)
    @test occursin("No revisions on September 22nd.", html)
end

@testset "activity: levels are the quartiles of the days that saw anything" begin
    # counts 1,2,3,4 → quartiles at 1, 2, 3: each day lands in its own step
    @test Archeion.levels_of(Dict(Date(2026, 1, i) => i for i in 1:4)) == [1, 2, 3]
    @test [Archeion.level(n, [1, 2, 3]) for n in 0:5] == [0, 1, 2, 3, 4, 4]
    # one busy day among quiet ones does not push the quiet ones up
    th = Archeion.levels_of(Dict(Date(2026, 1, i) => (i == 9 ? 40 : 1) for i in 1:9))
    @test Archeion.level(1, th) == 1 && Archeion.level(40, th) == 4
    @test Archeion.level(5, Int[]) == 0                # nothing to compare against
end

@testset "activity: months label the weeks that belong to them" begin
    html = Archeion.activity(frozen_on([DateTime(2026, 9, 21, 6)]); today=TODAY)
    spans = [
        (m[1], m[2]) for m in
        eachmatch(r"colspan=\"(\d+)\"[^>]*>\s*<span class=\"sr-only\">(\w+)</span>", html)
    ]
    @test length(spans) == 13                          # a year touches thirteen months
    @test sum(parse(Int, s[1]) for s in spans) == 53    # every week column is claimed once
    @test last(spans)[2] == "September" && first(spans)[2] == "September"
end

@testset "activity: what fell outside the year is said, not dropped" begin
    html = Archeion.activity(
        frozen_on([
            DateTime(2026, 9, 21, 1), DateTime(2026, 9, 21, 9), DateTime(2024, 5, 4)
        ]);
        today=TODAY,
    )
    @test occursin("2 revisions on September 21st.", html)
    @test occursin("<h2>2 revision(s) in the last year</h2>", html)
    @test occursin("1 revision(s) before it", html)
    @test occursin("2025-09-21 to\n    2026-09-23", html) ||
        occursin("2025-09-21 to 2026-09-23", replace(html, r"\s+" => " "))
    @test Archeion.activity([(; revs=[])]; today=TODAY) == ""   # nothing frozen, nothing drawn
end
