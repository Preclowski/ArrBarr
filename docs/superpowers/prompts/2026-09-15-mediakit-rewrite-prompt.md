# MediaKit: przepisanie warstwy komunikacji ArrBarr

Prompt dla Fable 5.1 jako koordynatora w trybie Workflow. Repo: `/Users/konrad/Workspace/ai/ArrBarr/ArrBarr`, branch `main`, czysty.

## 0. Cel, rola, miary

Przepisujesz warstwę komunikacji ArrBarr w jeden pakiet `Packages/MediaKit`: transport, limity, cache z persystencją, unieważnianie, tożsamość, zdolności usług, klienci wszystkich arrów, klientów pobierania, serwerów mediów i TMDB, oraz silnik kompozycji, z którego ArrCore składa swoje obiekty domenowe. Po migracji ArrCore nie wykonuje żadnego requestu HTTP samodzielnie.

Twoja rola: koordynator. Piszesz i akceptujesz spec sam. Właściciel podejmuje decyzje architektoniczne: dostaje paczki maksymalnie pięciu pytań wielokrotnego wyboru z rekomendacją i jednym zdaniem konsekwencji, na granicach faz. Nie dostaje prozy. Jeśli fakt z sekcji 2 okaże się fałszywy albo decyzja z sekcji 1 niewykonalna, nie naginasz planu po cichu: zgłaszasz w paczce pytań.

Cztery cele produktu i ich miary:

1. **Offline-first.** Poza LAN aplikacja renderuje ostatni znany stan natychmiast i nie alarmuje. Miara: po relaunchu z zablokowaną siecią popover i biblioteka renderują się z SQLite przed pierwszym requestem; nieosiągalny host nie produkuje UI błędu.
2. **Bez burz requestów.** Te same dane to jeden request. Miara: liczniki telemetrii per ekran nie gorsze niż baseline z fazy 0; drugie otwarcie detalu w oknie świeżości to zero requestów; grid 20 kart nie skaluje requestów z liczbą kart tam, gdzie źródło ma zasób batchowy lub indeks.
3. **Testowalne bez sieci.** Cały stos działa na fixture'ach. Miara: testy MediaKit i ArrCore nie dotykają `URLSession.shared`; transport testowy rzuca na każdy prawdziwy host.
4. **Lekkie.** Miara: kod produkcyjny MediaKit nie przekracza 60% linii, które zastępuje w ArrCore, policzonych w fazie 0; zero zależności zewnętrznych; widget iOS dalej linkuje i buduje się.

## 1. Decyzje nienegocjowalne

Każda z uzasadnieniem, bo od niego zależą kompromisy w projekcie.

1. **MediaKit to osobny pakiet SwiftPM i nigdy nie importuje ArrCore.** Konfiguracja, sekrety, zegar, transport, sink logów, podsystem logowania: wstrzykiwane. Bo granica wymuszona kompilatorem jest jedyną, która powstrzymuje sięganie po singletony; tak zgniła obecna warstwa.
2. **Zero zależności zewnętrznych w MediaKit.** Dozwolone: Foundation, os, Observation, Network, systemowy `SQLite3`, Swift Concurrency. Bo release z taga ma być odtwarzalny, a extension widgetu lekki. ArrCore zachowuje `swift-markdown`.
3. **Swift 6 w MediaKit, strict concurrency, zero ostrzeżeń.** `swift-tools-version: 6.2` we wszystkich manifestach, które buduje schemat `ArrBarr`. MediaKit: `defaultIsolation(nil)`, upcoming features `NonisolatedNonsendingByDefault` i `InferIsolatedConformances`, `@concurrent` dla pracy w tle, bo bez tej flagi `@concurrent` nic nie zmienia. ArrCore: `.defaultIsolation(MainActor.self)` w `Package.swift`, nie w xcconfig, bo izolację pakietu ustawia manifest; ArrCore zostaje w trybie języka v5, a przejście na v6 to osobne pytanie do właściciela.
4. **Persystencja faktów i indeksów: systemowy SQLite.** Bo unieważnianie po tagach potrzebuje indeksu, zimny start potrzebuje odczytu z dysku, limit rozmiaru potrzebuje zapytania, a plik da się obejrzeć `sqlite3` z terminala. Lokalizacja per platforma: macOS w Application Support kontenera sandboxu, bo aplikacja macOS nie ma app group i jest podpisana ad hoc; iOS w kontenerze `group.pl.incred.ArrBarr` z WAL, `busy_timeout` i ochroną plików `completeUntilFirstUserAuthentication` na db, wal i shm. `PosterStore` zostaje osobną warstwą bajtów i konsumuje z MediaKit jeden typ referencji grafiki.
5. **Typy domenowe ArrBarr zostają w ArrCore jako kompozycje.** MediaKit nie zna `QueueItem`, `UpcomingItem`, `HistoryItem`. Klienci zwracają zasoby w słowniku usługi. Bo pakiet nie może nosić słownika jednej aplikacji.
6. **W zakresie:** Radarr, Sonarr, Lidarr, Whisparr, qBittorrent, Transmission, Deluge, rTorrent, SABnzbd, NZBGet, Plex, Jellyfin, Emby, TMDB, SignalR jako źródło zdarzeń, demo jako transport fixture'ów, wykrywanie serwera mediów w LAN. Whisparr: dziś tylko kształt v3; probe ma rozróżniać v2 i v3, a pełny klient v2 powstaje tylko, jeśli właściciel udostępni instancję v2 do nagrania fixture'ów; inaczej v2 to udokumentowana luka.
7. **Poza zakresem:** providery LLM, hosting MCP, notyfikacje, indeks Spotlight, StoreKit, KVSync, widoki. `TonightBarr` i `TonightCore` nietknięte; mogą przestać się kompilować. Jeśli po podniesieniu podłogi schemat `ArrBarr` przestanie się rozwiązywać przez `TonightCore`, to pytanie w paczce, nie cicha poprawka.
8. **Podłoga macOS 26, iOS 26** w `project.pbxproj` i w manifestach `ArrCore`, `MediaKit`, `ArrMCPServer`. W tej samej fazie znikają wszystkie sprawdzenia `#available` dla 26: dziś 11 linii w 6 plikach plus 3 `@available` w `FoundationModelsProvider`.
9. **Branch `feat/mediakit-foundation`.** Commit po każdej fazie z prefiksem `phase(N):` i po każdym zielonym module. Nieudana faza to `git reset --hard` do commitu poprzedniej. Bez merge do `main`, bez push, bez tagów.
10. **Kod i komentarze po angielsku.** Komentarz tylko tam, gdzie "dlaczego" nie wynika z kodu, do dwóch linii. Nie naśladuj eseistycznych komentarzy obecnego repo. Uzasadnienia idą do specu, planu i commitów.
11. **Bez martwego kodu.** Stare klienty, cache i `RealtimeUpdates` w ArrCore znikają w ostatniej fali migracji, osobnym agentem, po nagraniu złotego korpusu requestów.
12. **Testy przed kodem** tam, gdzie zachowanie jest deterministyczne: transport, limiter, breaker, store, tożsamość, zdolności, dekodery, kształt requestów zapisu.
13. **API systemowe 26 w warstwie danych wchodzą od razu:** `Observations` jako most między unieważnieniem a widokiem; typowane wiadomości `NotificationCenter` dla zdarzeń warstwy danych, czyli zmiana konfiguracji, unieważnienie, łączność; `@concurrent`; swiftowe API `Network` do wykrywania serwera. Dwanaście dzisiejszych postów nawigacyjnych UI przechodzi na typowane wiadomości dopiero w fazie 7.
14. **Sekrety:** w nagłówkach wszędzie, gdzie protokół na to pozwala; w query tylko tam, gdzie nie ma innej drogi, czyli SABnzbd `apikey` i klucz TMDB v3. Nigdy w kluczu cache, logu, telemetrii ani fixture'ach. URL w logu zawsze bez query.
15. **Testy na żywych usługach właściciela wyłącznie odczytami** według sekcji 5, wymuszonymi w kodzie transportu, nie w prompcie.
16. **Adopcja API 26 w UI to osobna faza 7, wyłącznie target macOS.** iOS i iPad muszą się budować i przechodzić testy, ale nie dostają nowych funkcji.

## 2. Fakty o środowisku i hipotezy do obalenia

Zweryfikowane przed napisaniem tego promptu. Faza 0 zwraca tabelę: hipoteza, werdykt, dowód ze ścieżką i linią.

- Toolchain: lokalnie Xcode 27.0 (27A266a), SDK macOS 27.0 / iOS 27.0, Swift 6.4; przełączony w trakcie fazy 0 (start był na 26.4.1). CI (`.github/workflows/release.yml`) dalej przypina Xcode 26.4.1 na `macos-26`, więc manifesty zostają na `swift-tools-version: 6.2` i podłodze 26 (`.v27` istnieje dopiero w PackageDescription 6.4). Zweryfikowane w fazie 0 na pakiecie testowym: 6.2 + `.v26` + `defaultIsolation(nil)` + obie upcoming features + `import SQLite3` bez zależności budują się pod 6.4. Podniesienie CI do 27 to pytanie do właściciela.
- Graf pakietów: `ArrBarr` linkuje `ArrCore` i `ArrMCPServer`; `ArrMCPServer` zależy od `ArrCore` i ma podłogę macOS 14 w manifeście; `TonightCore` jest w grafie projektu, ale target `TonightBarr` nie jest budowany przez schemat `ArrBarr`. Wszystkie cztery manifesty mają `swift-tools-version: 6.0`.
- Widget: `ArrBarrWidgets` to target wyłącznie iOS, osadzony w `ArrBarriOS`. Sam pobiera dane z sieci przez `LibrarySummaryService` i `UpcomingService`, czyli przez klientów ArrCore, z sekretami z suite'u grupy i keychain. Nie czyta snapshotu aplikacji. Na macOS nie ma widgetu.
- Uprawnienia: `ArrBarr.entitlements` ma sandbox i sieć, bez `application-groups`; OSS podpis `CODE_SIGN_IDENTITY = "-"`, pusty team. iOS i widget mają `group.pl.incred.ArrBarr`.
- Konfiguracja: `ConfigStore` trzyma dokładnie jedną instancję per rodzaj usługi i jeden serwer mediów; jest `ObservableObject` z około 56 `@Published`; `QueueViewModel` debounce'uje zmiany przez Combine. Kadencja odpytywania kolejki to 30 s, wybuchy SignalR koalescowane w 0.25 s.
- Klienci ArrCore: `HTTPClient` i `ArrAPIClient` z `X-Api-Key`, timeouty 15 s i 120 s dla `/release`, `URLCache` wyłączony i ma tak zostać. Około 58 operacji w czterech arrach, `SearchClient` i `ArrDownloadClients`, w tym zapisy. Sześć klientów pobierania; Transmission, Deluge, rTorrent i NZBGet czytają przez POST RPC. `PlexClient`, `JellyfinClient` dla Jellyfin i Emby, `MediaServerIndex` jako snapshot za lockiem do odczytu w body widoków, `MediaServerPosterAccess` z sizingiem. `TMDBClient` z kluczem v3 w query albo tokenem v4 w Bearer.
- `RealtimeUpdates`: ręczny SignalR bez zależności zewnętrznych, ale używa `ServiceConfig`, `QueueItem.Source`, `DemoMode`, `Logger(category:)`; negocjacja to POST. Przeniesienie to przepisanie typów, nie przeniesienie pliku.
- Cache rozproszone: `TitleMetadataStore` 30 dni na dysku; `LibraryIndex` 10 min z wersjami i unieważnianiem na `fileImported` z `QueueViewModel`; `SearchOptionsCache` 15 min per fingerprint; `CoalescingCache`; cache plików w klientach 15 min; `SeriesIdentityResolver` z probe `term=tmdb:` tylko w pamięci. `PosterStore` z tierami icon, card, full.
- Fingerprint instancji dziś: base URL plus długość klucza. Klucze arrów mają stałe 32 znaki, więc rotacja klucza na tym samym URL jest niewykrywalna.
- Konsumenci: około 40 plików buduje klientów bezpośrednio, 58 miejsc w 15 plikach Views i ViewModels, m.in. `DetailView`, `MediaEditPanel`, `ReleaseListView`, `UpcomingRowView`, `MediaServerSettingsPane`. 28 narzędzi w `ChatToolCatalog`; MCP dochodzi przez `LocalToolBackend`. 103 typy `Codable` w ArrCore, 22 singletony `static shared`, 23 aktory, 124 `@MainActor`, 73 `nonisolated`.
- Demo: 46 gałęzi `DemoMode.isActive` w sześciu klientach, 17 w Views i ViewModels, `DemoMocks`, `DemoMonitorState`, `DemoQueueState` używane też z widgetu.
- Wersjonowanie: `apiBase` na sztywno; `SonarrClient.setSeasonMonitored` próbuje v5 i wraca do v3 na 404 lub 405; Whisparr v2 to fork Sonarra z `tvCategory`, v3 fork Radarra z `movieCategory`, klient obsługuje tylko v3; qBittorrent 4 loguje się cookie SID, 5 przyjmuje klucz API; Lidarr `/api/v1`.
- Limity: tylko `maxConcurrentSideLoads = 4` i `ParallelResolve`; backoff tylko w SignalR; 429 nieobsługiwane nigdzie.
- Testy: 94 pliki w `ArrCoreTests`, Swift Testing; stuby `URLProtocol` filtrują po hoście. `Tools/loc/lint_missing_keys.py` sprawdza katalog stringów.
- Foundation Models: `FoundationModelsProvider` ma już `DynamicMCPTool: Tool` opakowujący każde narzędzie katalogu jednym argumentem `@Generable { json: String }`. `AppShortcutsProvider` eksponuje 3 z 6 intencji.
- MediaKit spike z 2026-09-13: 3440 linii, tryb Swift 6, zero zależności, używany tylko przez `TonightCore`. Dobre idee: tożsamość wielo-id per rodzaj, `MediaFieldSet`, providery z kosztem i precedencją per pole, `FragmentCache` z koalescencją, `MediaGraph`, intencje katalogowe, `MediaTelemetry`, wstrzykiwany `HTTPTransport`, `MediaServerArtworkSizing`. Braki: cache tylko w pamięci, brak zapisów, brak zdolności, brak limitów, `ProviderHealth` nigdy nie ustawiany, `BatchMediaProvider` nieużywany, pole `.title` zlepia pięć faktów, klucz API w query. Słownik pojęć, nie kod do zachowania.
- Reguły z `CLAUDE.md` obowiązują: poziomy logów, prywatność pól, nigdy cały URL, `AppSignpost` na timingi, lokalizacja przez `Bundle.module` w ArrCore, słowo "tinder" zakazane.

## 3. Hipoteza architektury

Punkt startowy dla fazy 1. Faza 1 może zastąpić wszystko poniżej poza sekcją 1. Opisane są odpowiedzialności i reguły, nie sygnatury; jedyny szkic kodu pokazuje kształt, nie API.

**Warstwy od dołu**

1. **Transport.** Wysyła jeden request, zwraca status, nagłówki, bajty. Implementacje: `URLSessionTransport`; `FixtureTransport` odpowiadający nagraniami po metodzie i wzorcu ścieżki lub nazwie metody RPC, z małym stanem dla demo; `RecordingTransport` z listą dozwolonych operacji w kodzie i usuwaniem sekretów przed zapisem. Timeout per request. Anulowanie propagowane.
2. **Kernel.**
   - Limiter: współbieżność per host, tempo per host z priorytetami `interactive` i `background`. Priorytet ustawia wywołujący raz per kompozycja; odpytywanie strumieni żywych jest zawsze `background`.
   - Retry: backoff z jitterem, `Retry-After` honorowany, retry tylko dla odczytów i jawnie idempotentnych zapisów.
   - Breaker per host: healthy, degraded, down; rozróżnia nieosiągalny, błąd HTTP, nieskonfigurowany. Jest jedynym źródłem prawdy o zdrowiu usług; `ConnectionHealthMonitor` i `ServerStatusModel` czytają z niego albo znikają.
   - Store: pamięć plus SQLite. `FreshnessClass` zasobu decyduje o tierze, retencji i domyślnym TTL; `maxAge` przy odczycie może tylko zaostrzyć. Volatile nigdy na dysku. Stale-while-revalidate. Koalescencja identycznych żądań w locie z licznikiem oczekujących: anulowanie jednego z dwóch czekających nie przerywa requestu, przerywa go dopiero wyjście ostatniego. Schemat: `entries(key PK, payload, fetched_at, last_used, fingerprint, class, stale_at)` i `entry_tags(tag, entry_key)`; unieważnienie ustawia `stale_at`, nie kasuje, bo breaker i pierwszy render serwują stale; `PRAGMA user_version`; "skasuj i odbuduj" tylko dla tabel cache, a zdolności i ostatni znany stan mają własne tabele, które przeżywają migrację.
   - Instancje: jedna per rodzaj usługi dziś, ale wszystko kluczowane `InstanceID`, żeby druga instancja nie wymagała zmiany schematu. Fingerprint = base URL plus pierwsze 8 bajtów SHA-256 klucza; nigdy klucz. `CredentialProvider` pytany per request; `InstanceRegistry` przelicza fingerprint po zmianie konfiguracji i unieważnia jej wpisy natychmiast.
   - Tożsamość: jeden model dla filmu, serialu, sezonu, odcinka, artysty, albumu, utworu, osoby, z rodzicem i porządkową dla elementów złożonych; tabela cross-walk `(namespace, value, kind, confidence, source, fetched_at)`; resolvery z pewnością. Zastępuje `MediaRef`, `MediaID`, `MediaServerExternalKey`, `SeriesIdentityResolver`, `MediaServerGuidParser`.
   - Zdolności: probe `/system/status` i odpowiedniki, zbiór zdolności per instancja na dysku. Gdy probe zawiedzie: ostatni zapisany zbiór, a bez niego konserwatywny domyślny per rodzaj; ponowny probe po następnym udanym statusie lub zmianie wersji; nigdy błąd dla użytkownika. Endpoint wybierany po zdolności, nigdy po numerze wersji w kodzie klienta.
   - Zdarzenia: źródła z `AsyncStream`: SignalR arrów, polling klientów pobierania, wybudzenie systemu. Mapowanie zdarzenia na tagi w jednym miejscu. Do konsumentów zmiany płyną przez `Observations`.
   - Telemetria i logi: zdarzenia request, response, cacheHit, cacheMiss, coalesced, skipped, failure, invalidated; liczniki per host i zasób; raport tekstowy bez sekretów. Podsystem i sink logów wstrzyknięte, żeby `log show` z `CLAUDE.md` dalej działał. Timingi przez signposty. Store wystawia `sweep` i `purge(class:)` i rejestruje się w `AppCaches`.
   - Wykrywanie: Plex przez Bonjour `_plexmediasvr._tcp`, Jellyfin i Emby przez UDP 7359; wynik to kandydaci do podpowiedzi w Settings, nic nie zapisuje się samo.
3. **Klienci usług** wystawiają zasoby i komendy w słowniku usługi. Zasób: klucz bez sekretu, tagi unieważnień, klasa świeżości, funkcja pobrania. Komenda: deklaruje tagi, które unieważnia; wariant optymistyczny stosuje się wyłącznie do ostatniej wartości strumienia żywego ze znacznikiem `pending`, który wygasa po odpowiedzi lub timeoucie; store nigdy nie jest zapisywany optymistycznie. Komendy długotrwałe arrów mają śledzenie stanu. Referencja grafiki: URL, nagłówki, sizing, klucz cache bez tokenu; łączy `MediaServerArtworkSizing` z MediaKit, `MediaServerPosterAccess` i `PosterTier.cdnVariant` z ArrCore oraz `TMDBClient.imageURL`; zastępuje wejścia `PosterStore.image(for:tier:apiKey:)`.
4. **Silnik kompozycji.** Aplikacja składa obiekt z zasobów przez kontekst, który zapisuje odczytane zasoby, więc wynik ma provenance, minimalną świeżość i sumę tagów. Memoizacja: klucz to wartość kompozycji (`Hashable`), tylko w pamięci, unieważniana tagami, emituje przez `Observations`; wynik częściowy nie jest memoizowany dalej niż do następnego odczytu. Odczyt batchowy batchuje po zasobach batchowych, koalescuje i respektuje limiter. Częściowe wyniki to norma.
5. **Strumienie żywe** dla kolejki, postępu i sesji: `AsyncStream` zasilany pollingiem i pushem; ostatnia wartość zapisywana jako jeden wiersz "ostatni znany" per instancja dla zimnego startu; kompozycje konsumują wartości strumienia i nigdy nie czytają zasobu volatile przez kontekst.
6. **Snapshot synchroniczny** dla ścieżek czytanych w body widoków: typowana projekcja wierszy store dla zadeklarowanych tagów, przebudowywana po unieważnieniu, `(value, version)` za lockiem. Dwóch konsumentów dziś: URL posterów i stan "obejrzane". `await` nie wchodzi do body widoków.
7. **Błędy:** zamknięty enum z ładunkiem: host, status, `retryAfter`, rodzaj usługi. Bez literałów użytkownika. ArrCore ma jeden wyczerpujący mapper na klucze katalogu, sprawdzany testem i `Tools/loc/lint_missing_keys.py`.
8. **Demo:** fake-serwer za `FixtureTransport` jest właścicielem całego stanu demo; ArrCore zachowuje jedną flagę `isDemo` do odznak i wyboru transportu; `DemoMocks`, `DemoMonitorState`, `DemoQueueState` znikają albo stają się danymi fixture'ów.

**Szkic kształtu, nie API**

```swift
// MediaKit
struct Resource<Value: Codable & Sendable>: Sendable {
    let key: ResourceKey              // instance + endpoint + params, never a secret
    let tags: Set<InvalidationTag>
    let freshness: FreshnessClass
    let fetch: @Sendable (Transport) async throws -> Value
}

extension Radarr {
    func movie(_ id: Int) -> Resource<RadarrMovie>
    func movieFiles(_ ids: [Int]) -> Resource<[RadarrMovieFile]>
}

// ArrCore: one record, three read policies
let movie = radarr.movie(id)
let title    = try await ctx.read(movie, maxAge: .days(30)).title
let overview = try await ctx.read(movie, maxAge: .hours(6)).overview
let ratings  = try await ctx.read(movie, maxAge: .hours(1)).ratings
```

## 4. Kryteria akceptacji

Każde ma dowód: test w nazwanym pliku albo komenda z oczekiwanym wynikiem. Liczby względne odnoszą się do baseline z fazy 0.

1. Ten sam zasób dwa razy w oknie świeżości: zero requestów za drugim razem. Test store.
2. Dwa równoległe odczyty tego samego zasobu: jeden request; anulowanie jednego czekającego nie przerywa drugiego. Test store.
3. Komenda deklaruje tagi; po niej następny odczyt zależnego zasobu idzie do sieci. Test store i klienta.
4. Zdarzenie SignalR unieważnia tylko opisane tagi. Test zdarzeń na fixture'ach ramek.
5. Zmiana base URL albo rotacja klucza na tym samym URL unieważnia wpisy instancji natychmiast. Test rejestru instancji.
6. Klasa volatile nigdy nie trafia do SQLite. Test na pustej tabeli po serii odczytów.
7. 429 z hosta blokuje ten host do `Retry-After`; inne hosty pracują. Test z fałszywym zegarem.
8. Limit współbieżności per host respektowany przy stu równoległych odczytach; wartość limitu jest parametrem testu. Test limitera.
9. Seria błędów transportu otwiera breaker; otwarty serwuje stale bez requestu; półotwarty wysyła jeden. Test breakera.
10. Anulowanie taska anuluje request ostatniego oczekującego i nie zapisuje częściowego wyniku. Test transportu.
11. Probe zdolności raz per fingerprint, po relaunchu z dysku; Sonarr bez v5 dostaje ścieżkę v3 bez błędu; probe rozróżnia Whisparr v2 i v3; niedostępny status daje ostatni zbiór albo domyślny. Testy zdolności na fixture'ach.
12. Sekret nie występuje w kluczu cache, logu, raporcie telemetrii ani w fixture'ach w repo. Test przeszukujący cztery źródła; w URL tylko dla SABnzbd i TMDB v3, i tylko w query.
13. Każdy przypadek enumu błędów ma klucz w katalogu ArrCore. Test mappera plus lint stringów.
14. Demo działa wyłącznie przez `FixtureTransport`; `grep DemoMode` w `Packages/MediaKit` daje zero.
15. Zimny start po relaunchu renderuje bibliotekę i ostatnią kolejkę z SQLite przed pierwszym requestem. Test integracyjny z transportem, który liczy requesty i opóźnia odpowiedź.
16. Widget iOS buduje się, linkuje MediaKit, nie używa klientów ArrCore i pobiera przez własne połączenie MediaKit; współdzielony SQLite w kontenerze grupy z WAL. Build `ArrBarrWidgets` plus grep.
17. Kompozycja z 20 kart nie skaluje requestów z liczbą kart tam, gdzie istnieje zasób batchowy lub indeks. Test kompozycji na fixture'ach.
18. `grep` na `RadarrClient(`, `SonarrClient(`, `LidarrClient(`, `WhisparrClient(`, `MediaServerClientFactory`, `TMDBClient(` w `Packages/ArrCore/Sources/ArrCore/Views` i `ViewModels`: zero.
19. 28 narzędzi chatu i MCP działa na fixture'ach; lista narzędzi niezmieniona. Testy `LocalToolBackend`.
20. `swift test` zielone w `MediaKit`, `ArrCore`, `ArrMCPServer`; schematy `ArrBarr`, `ArrBarriOS`, `ArrBarrWidgets` budują się; zero ostrzeżeń w MediaKit.
21. Raport telemetrii z Developer options zawiera per host: requesty, trafienia, chybienia, koalescencje, unieważnienia, otwarcia breakera.
22. Po fazie 3 `grep "#available(macOS 26\|#available(iOS 26\|@available(macOS 26"` w repo poza `Packages/TonightCore` daje zero.
23. Po fazie 5 zdarzenia warstwy danych idą typowanymi wiadomościami; po fazie 7 `grep "NotificationCenter.default.post(\|Notification.Name("` w `Packages/ArrCore/Sources`, `ArrBarr` daje zero.
24. ArrCore kompiluje się z `defaultIsolation(MainActor.self)` w manifeście; MediaKit z `defaultIsolation(nil)`; Views i ViewModels bez jawnych `@MainActor` na typach.
25. Wykrywanie znajduje Plex i Jellyfin z fixture'ów Bonjour i UDP bez sieci. Test parserów.
26. Złoty korpus requestów nagrany w fazie 0 zgadza się z requestami nowych klientów na tych samych operacjach, z dokumentowanymi wyjątkami. Diff w fazie 6.
27. Liczniki requestów per ekran, czas zimnego startu i czas `swift test` nie gorsze niż baseline z fazy 0; czas ramki listy biblioteki na macOS nie gorszy. Raport fazy 6.
28. Po fazie 7, tylko macOS: sześć intencji jako akcje Spotlight z parametrami; snippet statusu kolejki z pauzą i wznowieniem działa w Shortcuts i Spotlight; provider Foundation Models używa typowanych wyników `@Generable` dla Quizu i `suggest_titles`; decyzja o per-narzędziowych `@Generable` zamiast dzisiejszego argumentu JSON zapada w paczce pytań, nie w kodzie.

## 5. Usługi właściciela na żywo

Agent może odpytywać skonfigurowane usługi właściciela wyłącznie odczytami. Zakaz zmian trwałych i destrukcyjnych. Zakaz usuwania czegokolwiek na serwerach. Lista dozwolonych operacji żyje w kodzie `RecordingTransport` jako tabela metoda plus ścieżka lub nazwa metody RPC; wszystko spoza tabeli transport odrzuca przed wysłaniem.

| Usługa | Dozwolone | Zakazane |
|---|---|---|
| Arry | `GET`: `/system/status`, `/health`, `/diskspace`, `/queue`, `/history`, `/calendar`, `/movie`, `/series`, `/artist`, `/album`, `/episode`, `/episodefile`, `/moviefile`, `/trackfile`, `/track` (Lidarr), `/search` (Lidarr), `/qualityprofile`, `/rootfolder`, `/metadataprofile`, `/customformat`, `/downloadclient`, `/command`, `/*/lookup`, `/credit`, `/alttitle`; `POST /signalr/negotiate` i połączenie WebSocket | `GET /release` (uruchamia indeksery), każdy inny `POST`, `PUT`, `DELETE`: `/command`, `/release`, dodawanie, monitor, grab, kolejka, blocklist |
| qBittorrent | `POST /auth/login` raz per uruchomienie z ponownym użyciem sesji; `GET`: `app/version`, `app/preferences`, `torrents/info` | `torrents/*` akcje: stop, start, delete, add, setForceStart |
| Transmission | `POST` RPC: `session-get`, `torrent-get` | `torrent-start`, `torrent-stop`, `torrent-remove`, `torrent-add`, `session-set` |
| Deluge | `POST` RPC: `auth.login` raz, `daemon.info`, `core.get_torrents_status`, `core.get_config` | `core.pause_torrent`, `core.resume_torrent`, `core.remove_torrent`, `core.add_torrent_*` |
| rTorrent | `POST` XML-RPC: `system.client_version`, `d.multicall2`, `system.listMethods` | `d.start`, `d.stop`, `d.erase`, `load.*` |
| SABnzbd | `GET` `mode=version`, `mode=queue`, `mode=history` | `mode=pause`, `mode=resume`, `mode=addfile`, `mode=addurl`, `name=delete` |
| NZBGet | `POST` RPC: `version`, `listgroups`, `history`, `status` | `editqueue`, `append`, `pausedownload`, `resumedownload` |
| Plex | `GET`: `/identity`, `/library/sections`, `/library/sections/{key}/all`, `/status/sessions`, `/library/metadata/{id}`, historia | `/library/sections/{key}/refresh`, `/library/sections/{key}/emptyTrash`, `/photo/:/transcode` w nagraniach |
| Jellyfin, Emby | `GET`: `/System/Info`, `/Users`, `/Items`, `/Sessions`, `/Users/{id}/Items` | `/Library/Refresh`, `/Items/{id}` z `POST` lub `DELETE`, `/Sessions/*/Playing` |
| TMDB | dowolny `GET` poza `/authentication/*` | `/authentication/*`, `/account/*` z zapisem |
| Wykrywanie | zapytania Bonjour i UDP 7359 | nic więcej |

Logowania: jedno na klienta na uruchomienie, sesja wielokrotnego użytku; qBittorrent banuje IP po serii nieudanych logowań. Zapisy testowane przez `FixtureTransport` i testy kształtu requestu: metoda, URL, nagłówki, body, tagi. Fixture'y nagrywane w jednym seryjnym kroku fazy 0, z sekretami usuniętymi przed zapisem do repo. Do repo trafiają wyłącznie fixture'y po `Tools/fixtures/anonymize_fixtures.py`: tytuły, opisy, identyfikatory zewnętrzne, grafiki i nazwy plików zastąpione katalogiem open-source z `DemoMocks` (Big Buck Bunny, Sintel, …); surowe nagrania biblioteki właściciela zostają poza repo. Decyzje właściciela po fazie 0: ArrCore dostaje `defaultIsolation(MainActor.self)` w fazie 5 po usunięciu starych klientów (tryb v6 osobno później); widget czyta SQLite z kontenera grupy i odświeża własnym połączeniem MediaKit; Whisparr = klient v3 wyprowadzony z Radarra na fixture'ach syntetycznych, v2 udokumentowana luka.

## 6. Proces, agenci, modele

Mechanika Workflow: jedna faza to jedno wywołanie Workflow, poniżej 15 agentów. Etapy sekwencyjne zapisujesz jako `pipeline`, równoległe implementacje w worktree. **Nie używaj `isolation: 'worktree'`**: w fazie 0 okazało się, że tworzy worktree z `origin/main` (ac23c34, 32 commity za branchem), bez `Packages/MediaKit` i `TonightCore`. Koordynator tworzy worktree sam przed każdą fazą (`git worktree add <scratchpad>/wt-<zadanie> -b wt/<zadanie> feat/mediakit-foundation`), podaje agentowi ścieżkę i każe pracować wyłącznie w niej; integrator scala przez `git merge --no-ff` gałęzi `wt/*` do brancha fazy i usuwa worktree. Każdy implementer zwraca raport w schemacie JSON: `build_ok`, `tests_ok`, `grep_gates`, `files_touched`, `open_questions`; integrator odrzuca scalenie z jakimkolwiek `false`. Jeden implementer na zadanie, bez recenzenta per zadanie; adwersarialny review tylko tam, gdzie wskazano.

Koordynator: Ty, Fable 5.1, effort `xhigh`. Pod-koordynatorzy faz z wieloma etapami: Fable, effort `high`. Modele agentów według tabeli; `opus` tam, gdzie liczy się poprawność współbieżnego kodu, `sonnet` tam, gdzie zadanie jest mechaniczne i ma kontrakt w testach, `haiku` do bramek grep i formatowania raportów.

| Faza | Agenci | Obsada, model, effort |
|---|---|---|
| 0 Inwentarz i baseline | 6 | 4 czytelników `sonnet medium` ze schematem wyjścia: arry i modele; klienci pobierania i progress; serwery mediów, TMDB, postery; konsumenci w Views, ViewModels, tools, MCP, widget, intents. Każda liczba z komendą i wynikiem. 1 rejestrator `sonnet medium`, seryjnie: baseline liczników per ekran, czas zimnego startu, czas `swift test`, czas ramki listy; złoty korpus requestów starych klientów; fixture'y z dozwolonych odczytów przez `RecordingTransport`. 1 pod-koordynator `fable high`: tabela hipotez z werdyktami, próbny build schematu `ArrBarr` po podniesieniu podłogi w worktree, lista pytań. |
| Decyzje | 0 | Paczka pytań: m.in. tryb języka ArrCore, los widgetu przy odczycie z SQLite, Whisparr v2, druga instancja usługi. |
| 1 Projekt | 6 | 3 architektów `opus high` z różnych kątów: cache i unieważnianie; transport, limity, współbieżność; model, tożsamość, zdolności. 2 krytyków `fable high`: czy przeżyje realne call site'y ArrBarr; czy jest lekkie i idiomatyczne w Swift 6.2. 1 syntetyzator specu `fable xhigh`: zwycięzca plus najlepsze pomysły pozostałych, spec w `docs/superpowers/specs/YYYY-MM-DD-mediakit-foundation-design.md`, self-review na placeholdery, sprzeczności, dwuznaczności, zakres. |
| Decyzje | 0 | Paczka pytań. |
| 2 Plan | 2 | Planista `opus high`: plan w `docs/superpowers/plans/` z zadaniami, testami i wyłączną własnością plików per agent. Krytyk kompletności `sonnet medium`: plan kontra sekcja 4 i sekcja 3. |
| 3 Kernel | 8 | Kręgosłup protokołów i typów `fable xhigh`, bo od niego zależy wszystko. Równolegle w worktree: transport z limiterem, retry i breakerem `opus high`; store SQLite `opus high`; tożsamość i cross-walk `opus medium`; zdolności `sonnet medium`; zdarzenia z przeniesionym SignalR `sonnet high`, z zachowaniem istniejących testów ramek. Integrator `opus medium`. Adwersarialny review kernela `fable high`: obala gwarancje 1 do 12. W tej fazie podnosisz podłogę i usuwasz guardy. |
| Decyzje | 0 | Paczka pytań. |
| 4 Klienci i kompozycja | 10 | `sonnet medium`: Radarr z Whisparrem; Sonarr; Lidarr; klienci torrentowi; klienci usenetowi; TMDB. `opus medium`: serwery mediów z guidami Plex. `opus high`: kompozycja danych żywych w ArrCore, czyli kolejka, postęp, historia; kompozycja faktów w ArrCore, czyli detale, biblioteka, upcoming, wyszukiwanie, dodawanie. Integrator `opus medium`. Klienci konsumują fixture'y z fazy 0, nie nagrywają. |
| Decyzje | 0 | Paczka pytań. |
| 5 Migracja ArrBarr | 9 | Przygotowanie `opus high`: jedna bramka usług w ArrCore, jedyny konstruktor instancji MediaKit, spięty z `ConfigStore` raz; potem call site'y tylko ją wołają. Fala 1 w worktree: kolejka, aggregator, upcoming i historia razem `opus high`, bo wszystkie żyją w `QueueViewModel`; detale, sezony, odcinki, artysta `sonnet medium`; biblioteka, search, add, edit, delete `sonnet medium`. Fala 2: tools i MCP `sonnet medium`; settings, health, status `sonnet medium`; widget iOS i intents `sonnet medium`. Integrator po każdej fali `opus medium`. Na końcu, sam: usunięcie starych klientów, cache, `RealtimeUpdates`, `ConnectionHealthMonitor` i mocków demo `sonnet low`. |
| 6 Weryfikacja | 6 | Soczewki: współbieżność i poprawność `fable high`; semantyka cache i unieważnień `opus high`; parytet z korpusem złotym i baseline `sonnet medium`. Naprawiacze batchowo 2 × `opus medium`. Weryfikator `sonnet low`: build trzech schematów, trzy `swift test`, lint stringów, relaunch, raport z telemetrii. |
| Decyzje | 0 | Paczka pytań. Warstwa danych musi być zielona przed fazą 7. |
| 7 API 26, tylko macOS | 4 | Spotlight i `SnippetIntent` `opus medium`: sześć intencji jako akcje z parametrami, snippet kolejki z pauzą i wznowieniem, `AppShortcutsProvider` na wszystkie sześć. Foundation Models `opus high`: `@Generable` dla Quizu i `suggest_titles`, strumieniowanie częściowych wyników, wariant narzędzi według decyzji właściciela. Typowane wiadomości dla dwunastu postów nawigacyjnych `sonnet medium`. Integrator `sonnet medium`: build, testy, relaunch, czas ramki listy. Bez zmian funkcjonalnych w iOS. |

Definicja ukończenia fazy: testy zielone, buildy zielone, commit `phase(N):`, jednozdaniowe podsumowanie, paczka pytań tam, gdzie tabela ją przewiduje.

## 6a. Narzędzia Xcode 27: serwer MCP `xcode` i skille

Serwer MCP `xcode` (`xcrun mcpbridge`, w `~/.claude.json` per projekt) i skille agenta Xcode 27 (`swiftui-specialist`, `device-interaction`, `test-modernizer`) są dostępne od restartu sesji po fazie 0. Agenci Workflow ładują je przez `ToolSearch` (`select:mcp__xcode__<Nazwa>`); każdy prompt agenta, którego to dotyczy, nazywa narzędzie wprost. Zasady:

1. **Fakty o API tylko z dokumentacji.** Każdy agent, który projektuje lub pisze kod na API 26/27 (`Observations`, typowane wiadomości `NotificationCenter`, `@concurrent`, `NWBrowser`, `SnippetIntent`, Foundation Models `@Generable`, `SQLite3`), przed użyciem symbolu woła `DocumentationSearch` i cytuje w raporcie nazwę modułu i sygnaturę. Sygnatura z pamięci, której nie da się potwierdzić, to `open_question`, nie kod. Dotyczy architektów fazy 1, kręgosłupa fazy 3, kompozycji fazy 4 i całej fazy 7.
2. **Build i diagnostyka w głównym drzewie przez Xcode.** Integratorzy i weryfikator używają `BuildProject` + `GetBuildLog` (filtr po severity) zamiast `xcodebuild | tail`, a bramkę "zero ostrzeżeń w MediaKit" liczą z `GetBuildLog` po schemacie `MediaKit` plus `XcodeRefreshCodeIssuesInFile` na każdym pliku pakietu. Worktree'y równoległych implementerów nie są otwarte w Xcode, więc tam zostaje `xcodebuild` z sekcji 7; `swift test` w pakietach zostaje wszędzie.
3. **Ustawienia projektu przez narzędzia, nie sed.** Podniesienie `MACOSX_DEPLOYMENT_TARGET` / `IPHONEOS_DEPLOYMENT_TARGET` w fazie 3 idzie przez `GetTargetBuildSettings` + `UpdateTargetBuildSetting` dla każdego targetu; po operacji diff `project.pbxproj` ma zawierać tylko te klucze. Xcode 27 może dopisać `LastUpgradeCheck` przy otwarciu projektu; taką zmianę commituje się osobno albo odrzuca, nigdy w commicie fazy.
4. **Sondy zachowania przez `RunCodeSnippet`.** Pytania w stylu "czy `Observations` emituje po mutacji w tym samym ticku", "jaką wersję SQLite ma SDK", "czy `NotificationCenter.Message` wymaga `Sendable`" rozstrzyga snippet w kontekście pliku MediaKit, a nie test-rozpoznanie. Wynik trafia do specu lub planu jednym zdaniem.
5. **Telemetria i zimny start z konsoli Xcode.** W fazie 6 weryfikator uruchamia aplikację przez `RunProject` i czyta OSLog przez `GetConsoleOutput` (filtr po podsystemie `pl.incred.ArrBarr`, kategorie MediaKit); raport per host i czas do pierwszego renderu z SQLite pochodzą stąd. `log stream` zostaje jako fallback. Właściciel nadal weryfikuje wizualnie sam; `RunProject` nie zastępuje relaunchu z sekcji 7, bo popover ma się zachowywać jak z Findera, nie spod debuggera.
6. **iOS: smoke bez screenshotów dla właściciela.** Integrator fali 2 fazy 5 i weryfikator fazy 6 używają `DeviceInteractionStartWorkspaceSession` → `DeviceInteractionInstallAndRun` → `DeviceInteractionSynthesize` na symulatorze, żeby potwierdzić, że aplikacja iOS i widget startują i renderują kolejkę z fixture'ów demo; skill `device-interaction` opisuje sekwencję. Zrzuty służą agentowi do stwierdzenia faktu, nie idą do właściciela.
7. **Skille.** `swiftui-specialist` ładują agenci dotykający Views w fazach 5 i 7. `test-modernizer` nie jest potrzebny: pakiety są już na Swift Testing. `uikit-app-modernization`, `c-bounds-safety`, `audit-xcode-security-settings` nie dotyczą tego projektu.
8. **Poza użyciem.** `GetTopCrashIssues` i field performance wymagają App Store Connect. `LocalizationPlanner` i `StringCatalog*` wymagają skilli `xcode-integration`, których sesja nie ma; klucze katalogu dalej idą przez `Tools/loc`. `XcodeWrite`/`XcodeUpdate` nie zastępują zwykłej edycji plików w pakietach SwiftPM, bo pliki pakietu nie są w strukturze projektu.

## 7. Komendy

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
```

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarriOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build build
```

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarrWidgets -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build build
```

```bash
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

```bash
(cd Packages/MediaKit && swift test)
```

```bash
(cd Packages/ArrCore && swift test)
```

```bash
(cd Packages/ArrMCPServer && swift test)
```

```bash
python3 Tools/loc/lint_missing_keys.py
```

Po każdej zmianie kodu: build, testy, relaunch. Właściciel weryfikuje wizualnie sam; nie rób screenshotów. W głównym drzewie build przez `BuildProject`/`GetBuildLog` (sekcja 6a); powyższe komendy `xcodebuild` obowiązują w worktree'ach i jako fallback.

## 8. Raport końcowy

Jedna strona: co powstało i gdzie; każde kryterium z sekcji 4 z nazwą testu lub komendą i wynikiem; baseline kontra stan końcowy; co poza zakresem; decyzje otwarte. Bez prozy.
