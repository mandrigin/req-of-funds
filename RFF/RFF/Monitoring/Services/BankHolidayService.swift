import Foundation

/// Represents a bank holiday from the Nager.Date API
struct BankHoliday: Codable, Equatable {
    let date: String  // ISO format: yyyy-MM-dd
    let localName: String
    let name: String
    let countryCode: String
    let fixed: Bool
    let global: Bool
    let counties: [String]?
    let launchYear: Int?
    let types: [String]

    /// Parse the date string into a Date object
    var parsedDate: Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: date)
    }
}

/// Service for fetching and caching bank holidays from the Nager.Date API
final class BankHolidayService {

    // MARK: - Singleton

    static let shared = BankHolidayService()

    // MARK: - Properties

    private let baseURL = "https://date.nager.at/api/v3"
    private let cache = NSCache<NSString, NSArray>()
    private var diskCache: [String: [BankHoliday]] = [:]
    private let cacheQueue = DispatchQueue(label: "com.invoicefiler.bankholiday.cache")
    private let urlSession: URLSession

    /// File URL for persistent cache
    private var cacheFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cacheDir = appSupport.appendingPathComponent("RFF").appendingPathComponent("Cache")
        return cacheDir.appendingPathComponent("bank_holidays.json")
    }

    // MARK: - Initialization

    private init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: config)

        loadDiskCache()
    }

    // MARK: - Public API

    /// Fetch bank holidays for a country and year
    /// - Parameters:
    ///   - countryCode: ISO 3166-1 alpha-2 country code (e.g., "US", "GB", "DE")
    ///   - year: The year to fetch holidays for
    ///   - completion: Completion handler with holidays or error
    func fetchHolidays(
        countryCode: String,
        year: Int,
        completion: @escaping (Result<[BankHoliday], Error>) -> Void
    ) {
        let cacheKey = "\(countryCode.uppercased())-\(year)"

        // Check memory cache
        if let cached = cache.object(forKey: cacheKey as NSString) as? [BankHoliday] {
            completion(.success(cached))
            return
        }

        // Check disk cache
        var foundInDiskCache = false
        cacheQueue.sync {
            if let cached = diskCache[cacheKey] {
                cache.setObject(cached as NSArray, forKey: cacheKey as NSString)
                completion(.success(cached))
                foundInDiskCache = true
            }
        }
        if foundInDiskCache {
            return
        }

        // Fetch from API
        let urlString = "\(baseURL)/PublicHolidays/\(year)/\(countryCode.uppercased())"
        guard let url = URL(string: urlString) else {
            completion(.failure(BankHolidayError.invalidURL))
            return
        }

        let task = urlSession.dataTask(with: url) { [weak self] data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(BankHolidayError.invalidResponse))
                return
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 404 {
                    completion(.failure(BankHolidayError.countryNotSupported(countryCode)))
                } else {
                    completion(.failure(BankHolidayError.httpError(httpResponse.statusCode)))
                }
                return
            }

            guard let data = data else {
                completion(.failure(BankHolidayError.noData))
                return
            }

            do {
                let holidays = try JSONDecoder().decode([BankHoliday].self, from: data)

                // Cache the result
                self?.cache.setObject(holidays as NSArray, forKey: cacheKey as NSString)
                self?.cacheQueue.async {
                    self?.diskCache[cacheKey] = holidays
                    self?.saveDiskCache()
                }

                completion(.success(holidays))
            } catch {
                completion(.failure(error))
            }
        }

        task.resume()
    }

    /// Fetch bank holidays synchronously (blocking)
    /// - Parameters:
    ///   - countryCode: ISO 3166-1 alpha-2 country code
    ///   - year: The year to fetch holidays for
    /// - Returns: Array of bank holidays
    /// - Throws: BankHolidayError if fetch fails
    func fetchHolidaysSync(countryCode: String, year: Int) throws -> [BankHoliday] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[BankHoliday], Error>?

        fetchHolidays(countryCode: countryCode, year: year) { fetchResult in
            result = fetchResult
            semaphore.signal()
        }

        semaphore.wait()

        switch result {
        case .success(let holidays):
            return holidays
        case .failure(let error):
            throw error
        case .none:
            throw BankHolidayError.noData
        }
    }

    /// Check if a specific date is a bank holiday in the given country
    /// - Parameters:
    ///   - date: The date to check
    ///   - countryCode: ISO 3166-1 alpha-2 country code
    ///   - completion: Completion handler with boolean result
    func isHoliday(
        date: Date,
        countryCode: String,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)

        fetchHolidays(countryCode: countryCode, year: year) { result in
            switch result {
            case .success(let holidays):
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                dateFormatter.timeZone = TimeZone(identifier: "UTC")
                let dateString = dateFormatter.string(from: date)

                let isHoliday = holidays.contains { $0.date == dateString }
                completion(.success(isHoliday))

            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Get list of supported countries
    func fetchAvailableCountries(completion: @escaping (Result<[CountryInfo], Error>) -> Void) {
        let urlString = "\(baseURL)/AvailableCountries"
        guard let url = URL(string: urlString) else {
            completion(.failure(BankHolidayError.invalidURL))
            return
        }

        let task = urlSession.dataTask(with: url) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(BankHolidayError.noData))
                return
            }

            do {
                let countries = try JSONDecoder().decode([CountryInfo].self, from: data)
                completion(.success(countries))
            } catch {
                completion(.failure(error))
            }
        }

        task.resume()
    }

    /// Prefetch holidays for a range of years
    func prefetchHolidays(countryCode: String, years: [Int]) {
        for year in years {
            fetchHolidays(countryCode: countryCode, year: year) { _ in }
        }
    }

    /// Clear all cached data
    func clearCache() {
        cache.removeAllObjects()
        cacheQueue.async { [weak self] in
            self?.diskCache.removeAll()
            try? FileManager.default.removeItem(at: self?.cacheFileURL ?? URL(fileURLWithPath: ""))
        }
    }

    // MARK: - Disk Cache

    private func loadDiskCache() {
        cacheQueue.async { [weak self] in
            guard let self = self else { return }

            guard FileManager.default.fileExists(atPath: self.cacheFileURL.path) else {
                return
            }

            do {
                let data = try Data(contentsOf: self.cacheFileURL)
                self.diskCache = try JSONDecoder().decode([String: [BankHoliday]].self, from: data)
            } catch {
                // Cache corrupted, ignore
                try? FileManager.default.removeItem(at: self.cacheFileURL)
            }
        }
    }

    private func saveDiskCache() {
        // Ensure directory exists
        let cacheDir = cacheFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        do {
            let data = try JSONEncoder().encode(diskCache)
            try data.write(to: cacheFileURL, options: .atomic)
        } catch {
            // Ignore cache save errors
        }
    }
}

// MARK: - Supporting Types

struct CountryInfo: Codable {
    let countryCode: String
    let name: String
}

enum BankHolidayError: LocalizedError {
    case invalidURL
    case invalidResponse
    case noData
    case httpError(Int)
    case countryNotSupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL for bank holiday API"
        case .invalidResponse:
            return "Invalid response from bank holiday API"
        case .noData:
            return "No data received from bank holiday API"
        case .httpError(let code):
            return "Bank holiday API returned error: HTTP \(code)"
        case .countryNotSupported(let code):
            return "Country '\(code)' is not supported by the bank holiday API"
        }
    }
}
