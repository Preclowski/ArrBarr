import Foundation

/// TMDB has no awards endpoint, so the Awarded section carries its own
/// catalog: the top-prize winner of each ceremony, keyed by the film's own
/// year. Titles are resolved against TMDB at display time
/// (`TMDBService.movieMatch`), so only the winner list lives here — no
/// posters, ids or metadata to go stale.
public struct Award: Identifiable, Hashable, Sendable {
    public let id: String
    /// English name; localized through `Localizable.strings` like every
    /// other user-facing string.
    public let name: String
    public let categoryName: String
    public let symbol: String
    public let winners: [Winner]

    public struct Winner: Identifiable, Hashable, Sendable {
        /// The film's own release year — the year the poster will show.
        public let year: Int
        public let title: String
        public var id: Int { year }
    }

    public var displayName: String { String(localized: String.LocalizationValue(name), bundle: .module) }
    public var displayCategory: String { String(localized: String.LocalizationValue(categoryName), bundle: .module) }

    public var years: ClosedRange<Int> {
        let sorted = winners.map(\.year).sorted()
        return (sorted.first ?? 0)...(sorted.last ?? 0)
    }

    /// Decades represented, newest first — the year filter's chips.
    public var decades: [Int] {
        Set(winners.map { $0.year / 10 * 10 }).sorted(by: >)
    }

    public func winners(decade: Int?) -> [Winner] {
        let all = winners.sorted { $0.year > $1.year }
        guard let decade else { return all }
        return all.filter { $0.year / 10 * 10 == decade }
    }
}

public enum Awards {
    public static let all: [Award] = [academyAwards, cannes, goldenGlobes, bafta]

    public static func award(id: String) -> Award? {
        all.first { $0.id == id }
    }

    /// Academy Award for Best Picture, by film year (the ceremony is the
    /// following spring).
    public static let academyAwards = Award(
        id: "oscar-best-picture",
        name: "Academy Awards",
        categoryName: "Best Picture",
        symbol: "trophy",
        winners: [
            .init(year: 2024, title: "Anora"),
            .init(year: 2023, title: "Oppenheimer"),
            .init(year: 2022, title: "Everything Everywhere All at Once"),
            .init(year: 2021, title: "CODA"),
            .init(year: 2020, title: "Nomadland"),
            .init(year: 2019, title: "Parasite"),
            .init(year: 2018, title: "Green Book"),
            .init(year: 2017, title: "The Shape of Water"),
            .init(year: 2016, title: "Moonlight"),
            .init(year: 2015, title: "Spotlight"),
            .init(year: 2014, title: "Birdman"),
            .init(year: 2013, title: "12 Years a Slave"),
            .init(year: 2012, title: "Argo"),
            .init(year: 2011, title: "The Artist"),
            .init(year: 2010, title: "The King's Speech"),
            .init(year: 2009, title: "The Hurt Locker"),
            .init(year: 2008, title: "Slumdog Millionaire"),
            .init(year: 2007, title: "No Country for Old Men"),
            .init(year: 2006, title: "The Departed"),
            .init(year: 2005, title: "Crash"),
            .init(year: 2004, title: "Million Dollar Baby"),
            .init(year: 2003, title: "The Lord of the Rings: The Return of the King"),
            .init(year: 2002, title: "Chicago"),
            .init(year: 2001, title: "A Beautiful Mind"),
            .init(year: 2000, title: "Gladiator"),
            .init(year: 1999, title: "American Beauty"),
            .init(year: 1998, title: "Shakespeare in Love"),
            .init(year: 1997, title: "Titanic"),
            .init(year: 1996, title: "The English Patient"),
            .init(year: 1995, title: "Braveheart"),
            .init(year: 1994, title: "Forrest Gump"),
            .init(year: 1993, title: "Schindler's List"),
            .init(year: 1992, title: "Unforgiven"),
            .init(year: 1991, title: "The Silence of the Lambs"),
            .init(year: 1990, title: "Dances with Wolves"),
            .init(year: 1989, title: "Driving Miss Daisy"),
            .init(year: 1988, title: "Rain Man"),
            .init(year: 1987, title: "The Last Emperor"),
            .init(year: 1986, title: "Platoon"),
            .init(year: 1985, title: "Out of Africa"),
            .init(year: 1984, title: "Amadeus"),
            .init(year: 1983, title: "Terms of Endearment"),
            .init(year: 1982, title: "Gandhi"),
            .init(year: 1981, title: "Chariots of Fire"),
            .init(year: 1980, title: "Ordinary People"),
            .init(year: 1979, title: "Kramer vs. Kramer"),
            .init(year: 1978, title: "The Deer Hunter"),
            .init(year: 1977, title: "Annie Hall"),
            .init(year: 1976, title: "Rocky"),
            .init(year: 1975, title: "One Flew Over the Cuckoo's Nest"),
            .init(year: 1974, title: "The Godfather Part II"),
            .init(year: 1973, title: "The Sting"),
            .init(year: 1972, title: "The Godfather"),
            .init(year: 1971, title: "The French Connection"),
            .init(year: 1970, title: "Patton"),
            .init(year: 1969, title: "Midnight Cowboy"),
            .init(year: 1968, title: "Oliver!"),
            .init(year: 1967, title: "In the Heat of the Night"),
            .init(year: 1966, title: "A Man for All Seasons"),
            .init(year: 1965, title: "The Sound of Music"),
            .init(year: 1964, title: "My Fair Lady"),
            .init(year: 1963, title: "Tom Jones"),
            .init(year: 1962, title: "Lawrence of Arabia"),
            .init(year: 1961, title: "West Side Story"),
            .init(year: 1960, title: "The Apartment"),
            .init(year: 1959, title: "Ben-Hur"),
            .init(year: 1958, title: "Gigi"),
            .init(year: 1957, title: "The Bridge on the River Kwai"),
            .init(year: 1956, title: "Around the World in 80 Days"),
            .init(year: 1955, title: "Marty"),
            .init(year: 1954, title: "On the Waterfront"),
            .init(year: 1953, title: "From Here to Eternity"),
            .init(year: 1952, title: "The Greatest Show on Earth"),
            .init(year: 1951, title: "An American in Paris"),
            .init(year: 1950, title: "All About Eve"),
        ])

    /// Palme d'Or, by festival year.
    public static let cannes = Award(
        id: "cannes-palme-dor",
        name: "Cannes Film Festival",
        categoryName: "Palme d'Or",
        symbol: "laurel.leading",
        winners: [
            .init(year: 2025, title: "It Was Just an Accident"),
            .init(year: 2024, title: "Anora"),
            .init(year: 2023, title: "Anatomy of a Fall"),
            .init(year: 2022, title: "Triangle of Sadness"),
            .init(year: 2021, title: "Titane"),
            .init(year: 2019, title: "Parasite"),
            .init(year: 2018, title: "Shoplifters"),
            .init(year: 2017, title: "The Square"),
            .init(year: 2016, title: "I, Daniel Blake"),
            .init(year: 2015, title: "Dheepan"),
            .init(year: 2014, title: "Winter Sleep"),
            .init(year: 2013, title: "Blue Is the Warmest Colour"),
            .init(year: 2012, title: "Amour"),
            .init(year: 2011, title: "The Tree of Life"),
            .init(year: 2010, title: "Uncle Boonmee Who Can Recall His Past Lives"),
            .init(year: 2009, title: "The White Ribbon"),
            .init(year: 2008, title: "The Class"),
            .init(year: 2007, title: "4 Months, 3 Weeks and 2 Days"),
            .init(year: 2006, title: "The Wind That Shakes the Barley"),
            .init(year: 2005, title: "L'Enfant"),
            .init(year: 2004, title: "Fahrenheit 9/11"),
            .init(year: 2003, title: "Elephant"),
            .init(year: 2002, title: "The Pianist"),
            .init(year: 2001, title: "The Son's Room"),
            .init(year: 2000, title: "Dancer in the Dark"),
            .init(year: 1999, title: "Rosetta"),
            .init(year: 1998, title: "Eternity and a Day"),
            .init(year: 1997, title: "Taste of Cherry"),
            .init(year: 1996, title: "Secrets & Lies"),
            .init(year: 1995, title: "Underground"),
            .init(year: 1994, title: "Pulp Fiction"),
            .init(year: 1993, title: "The Piano"),
            .init(year: 1992, title: "The Best Intentions"),
            .init(year: 1991, title: "Barton Fink"),
            .init(year: 1990, title: "Wild at Heart"),
        ])

    /// Golden Globe for Best Motion Picture — Drama, by film year.
    public static let goldenGlobes = Award(
        id: "golden-globe-drama",
        name: "Golden Globes",
        categoryName: "Best Motion Picture — Drama",
        symbol: "globe",
        winners: [
            .init(year: 2024, title: "The Brutalist"),
            .init(year: 2023, title: "Oppenheimer"),
            .init(year: 2022, title: "The Fabelmans"),
            .init(year: 2021, title: "The Power of the Dog"),
            .init(year: 2020, title: "Nomadland"),
            .init(year: 2019, title: "1917"),
            .init(year: 2018, title: "Bohemian Rhapsody"),
            .init(year: 2017, title: "Three Billboards Outside Ebbing, Missouri"),
            .init(year: 2016, title: "Moonlight"),
            .init(year: 2015, title: "The Revenant"),
            .init(year: 2014, title: "Boyhood"),
            .init(year: 2013, title: "12 Years a Slave"),
            .init(year: 2012, title: "Argo"),
            .init(year: 2011, title: "The Descendants"),
            .init(year: 2010, title: "The Social Network"),
            .init(year: 2009, title: "Avatar"),
            .init(year: 2008, title: "Slumdog Millionaire"),
            .init(year: 2007, title: "Atonement"),
            .init(year: 2006, title: "Babel"),
            .init(year: 2005, title: "Brokeback Mountain"),
            .init(year: 2004, title: "The Aviator"),
            .init(year: 2003, title: "The Lord of the Rings: The Return of the King"),
            .init(year: 2002, title: "The Hours"),
            .init(year: 2001, title: "A Beautiful Mind"),
            .init(year: 2000, title: "Gladiator"),
        ])

    /// BAFTA Best Film, by film year.
    public static let bafta = Award(
        id: "bafta-best-film",
        name: "BAFTA",
        categoryName: "Best Film",
        symbol: "theatermasks",
        winners: [
            .init(year: 2024, title: "Conclave"),
            .init(year: 2023, title: "Oppenheimer"),
            .init(year: 2022, title: "All Quiet on the Western Front"),
            .init(year: 2021, title: "The Power of the Dog"),
            .init(year: 2020, title: "Nomadland"),
            .init(year: 2019, title: "1917"),
            .init(year: 2018, title: "Roma"),
            .init(year: 2017, title: "Three Billboards Outside Ebbing, Missouri"),
            .init(year: 2016, title: "La La Land"),
            .init(year: 2015, title: "The Revenant"),
            .init(year: 2014, title: "Boyhood"),
            .init(year: 2013, title: "12 Years a Slave"),
            .init(year: 2012, title: "Argo"),
            .init(year: 2011, title: "The Artist"),
            .init(year: 2010, title: "The King's Speech"),
            .init(year: 2009, title: "The Hurt Locker"),
            .init(year: 2008, title: "Slumdog Millionaire"),
            .init(year: 2007, title: "Atonement"),
            .init(year: 2006, title: "The Queen"),
            .init(year: 2005, title: "Brokeback Mountain"),
            .init(year: 2004, title: "The Aviator"),
            .init(year: 2003, title: "The Lord of the Rings: The Return of the King"),
            .init(year: 2002, title: "The Pianist"),
            .init(year: 2001, title: "The Lord of the Rings: The Fellowship of the Ring"),
            .init(year: 2000, title: "Gladiator"),
        ])
}
