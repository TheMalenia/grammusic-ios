import SwiftUI

struct Country: Identifiable, Hashable {
    let iso: String      // ISO 3166-1 alpha-2
    let dialCode: String // e.g. "+57"

    var id: String { iso }

    /// Localized country name from the OS (always complete & translated).
    var name: String {
        Locale.current.localizedString(forRegionCode: iso) ?? iso
    }

    /// Flag emoji derived from the ISO code (regional indicator symbols).
    var flag: String {
        iso.unicodeScalars.reduce("") { $0 + String(UnicodeScalar(127397 + $1.value)!) }
    }
}

enum Countries {
    /// Full ISO → dial-code table (ITU E.164). Names/flags are derived at runtime.
    static let dialCodes: [String: String] = [
        "AF": "+93", "AL": "+355", "DZ": "+213", "AD": "+376", "AO": "+244", "AG": "+1",
        "AR": "+54", "AM": "+374", "AU": "+61", "AT": "+43", "AZ": "+994", "BS": "+1",
        "BH": "+973", "BD": "+880", "BB": "+1", "BY": "+375", "BE": "+32", "BZ": "+501",
        "BJ": "+229", "BT": "+975", "BO": "+591", "BA": "+387", "BW": "+267", "BR": "+55",
        "BN": "+673", "BG": "+359", "BF": "+226", "BI": "+257", "KH": "+855", "CM": "+237",
        "CA": "+1", "CV": "+238", "CF": "+236", "TD": "+235", "CL": "+56", "CN": "+86",
        "CO": "+57", "KM": "+269", "CG": "+242", "CD": "+243", "CR": "+506", "CI": "+225",
        "HR": "+385", "CU": "+53", "CY": "+357", "CZ": "+420", "DK": "+45", "DJ": "+253",
        "DM": "+1", "DO": "+1", "EC": "+593", "EG": "+20", "SV": "+503", "GQ": "+240",
        "ER": "+291", "EE": "+372", "SZ": "+268", "ET": "+251", "FJ": "+679", "FI": "+358",
        "FR": "+33", "GA": "+241", "GM": "+220", "GE": "+995", "DE": "+49", "GH": "+233",
        "GR": "+30", "GD": "+1", "GT": "+502", "GN": "+224", "GW": "+245", "GY": "+592",
        "HT": "+509", "HN": "+504", "HK": "+852", "HU": "+36", "IS": "+354", "IN": "+91",
        "ID": "+62", "IR": "+98", "IQ": "+964", "IE": "+353", "IL": "+972", "IT": "+39",
        "JM": "+1", "JP": "+81", "JO": "+962", "KZ": "+7", "KE": "+254", "KI": "+686",
        "KW": "+965", "KG": "+996", "LA": "+856", "LV": "+371", "LB": "+961", "LS": "+266",
        "LR": "+231", "LY": "+218", "LI": "+423", "LT": "+370", "LU": "+352", "MO": "+853",
        "MG": "+261", "MW": "+265", "MY": "+60", "MV": "+960", "ML": "+223", "MT": "+356",
        "MH": "+692", "MR": "+222", "MU": "+230", "MX": "+52", "FM": "+691", "MD": "+373",
        "MC": "+377", "MN": "+976", "ME": "+382", "MA": "+212", "MZ": "+258", "MM": "+95",
        "NA": "+264", "NR": "+674", "NP": "+977", "NL": "+31", "NZ": "+64", "NI": "+505",
        "NE": "+227", "NG": "+234", "KP": "+850", "MK": "+389", "NO": "+47", "OM": "+968",
        "PK": "+92", "PW": "+680", "PS": "+970", "PA": "+507", "PG": "+675", "PY": "+595",
        "PE": "+51", "PH": "+63", "PL": "+48", "PT": "+351", "QA": "+974", "RO": "+40",
        "RU": "+7", "RW": "+250", "KN": "+1", "LC": "+1", "VC": "+1", "WS": "+685",
        "SM": "+378", "ST": "+239", "SA": "+966", "SN": "+221", "RS": "+381", "SC": "+248",
        "SL": "+232", "SG": "+65", "SK": "+421", "SI": "+386", "SB": "+677", "SO": "+252",
        "ZA": "+27", "KR": "+82", "SS": "+211", "ES": "+34", "LK": "+94", "SD": "+249",
        "SR": "+597", "SE": "+46", "CH": "+41", "SY": "+963", "TW": "+886", "TJ": "+992",
        "TZ": "+255", "TH": "+66", "TL": "+670", "TG": "+228", "TO": "+676", "TT": "+1",
        "TN": "+216", "TR": "+90", "TM": "+993", "TV": "+688", "UG": "+256", "UA": "+380",
        "AE": "+971", "GB": "+44", "US": "+1", "UY": "+598", "UZ": "+998", "VU": "+678",
        "VA": "+39", "VE": "+58", "VN": "+84", "YE": "+967", "ZM": "+260", "ZW": "+263",
        "PR": "+1", "GE_AB": "+995",
    ]

    static let all: [Country] = dialCodes
        .filter { $0.key.count == 2 }
        .map { Country(iso: $0.key, dialCode: $0.value) }
        .sorted { $0.name < $1.name }

    /// Preferred country for dial codes shared by several countries.
    private static let primaries: [String: String] = [
        "+1": "US", "+7": "RU", "+44": "GB", "+39": "IT", "+47": "NO", "+358": "FI",
    ]

    static func country(forDialCode code: String) -> Country? {
        if let iso = primaries[code], let c = all.first(where: { $0.iso == iso }) { return c }
        return all.first { $0.dialCode == code }
    }

    static var defaultCountry: Country {
        all.first { $0.iso == "US" } ?? Country(iso: "US", dialCode: "+1")
    }

    static var deviceDefault: Country {
        defaultCountry
    }
}

/// Formats national phone number digits into readable spaced chunks based on dial code rules.
enum PhoneNumberFormatter {
    static func format(nationalNumber: String, dialCode: String) -> String {
        let digits = nationalNumber.filter(\.isNumber)
        guard !digits.isEmpty else { return "" }
        
        switch dialCode {
        case "+1": // US / Canada: 3-3-4 (e.g. 555 019 2834)
            return format(digits: digits, chunks: [3, 3, 4])
        case "+44": // UK: 4-6 or 4-3-4 (e.g. 7911 123456)
            if digits.count > 10 {
                return format(digits: digits, chunks: [4, 3, 4])
            } else {
                return format(digits: digits, chunks: [4, 6])
            }
        case "+33": // France: 1-2-2-2-2 (e.g. 6 12 34 56 78)
            return format(digits: digits, chunks: [1, 2, 2, 2, 2])
        case "+49", "+39", "+34", "+31", "+32": // European: 3-3-4 or 3-4-4
            return format(digits: digits, chunks: [3, 3, 4])
        case "+7": // Russia / Kazakhstan: 3-3-2-2
            return format(digits: digits, chunks: [3, 3, 2, 2])
        case "+86": // China: 3-4-4
            return format(digits: digits, chunks: [3, 4, 4])
        case "+91": // India: 5-5
            return format(digits: digits, chunks: [5, 5])
        case "+98": // Iran: 3-3-4 (e.g. 912 345 6789)
            return format(digits: digits, chunks: [3, 3, 4])
        case "+81": // Japan: 3-4-4
            return format(digits: digits, chunks: [3, 4, 4])
        case "+61": // Australia: 3-3-3
            return format(digits: digits, chunks: [3, 3, 3])
        case "+55": // Brazil: 2-5-4
            return format(digits: digits, chunks: [2, 5, 4])
        case "+971": // UAE: 2-3-4
            return format(digits: digits, chunks: [2, 3, 4])
        case "+966": // Saudi Arabia: 2-3-4
            return format(digits: digits, chunks: [2, 3, 4])
        case "+90": // Turkey: 3-3-4
            return format(digits: digits, chunks: [3, 3, 4])
        default:
            if digits.count <= 8 {
                return format(digits: digits, chunks: [4, 4])
            } else if digits.count <= 10 {
                return format(digits: digits, chunks: [3, 3, 4])
            } else {
                return format(digits: digits, chunks: [3, 4, 4])
            }
        }
    }
    
    private static func format(digits: String, chunks: [Int]) -> String {
        var result = ""
        var currentIndex = digits.startIndex
        
        for (i, chunkSize) in chunks.enumerated() {
            guard currentIndex < digits.endIndex else { break }
            let nextIndex = digits.index(currentIndex, offsetBy: chunkSize, limitedBy: digits.endIndex) ?? digits.endIndex
            let chunk = digits[currentIndex..<nextIndex]
            if i > 0 && !result.isEmpty {
                result += " "
            }
            result += chunk
            currentIndex = nextIndex
        }
        
        if currentIndex < digits.endIndex {
            result += " " + digits[currentIndex...]
        }
        return result
    }
}

/// Searchable country list (name + dial code). Nocturne-themed.
struct NCountryPicker: View {
    @Binding var selection: Country
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [Country] {
        guard !search.isEmpty else { return Countries.all }
        return Countries.all.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.dialCode.contains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { country in
                Button {
                    selection = country
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text(country.flag).font(.title2)
                        Text(country.name).foregroundStyle(theme.text)
                        Spacer()
                        Text(country.dialCode).foregroundStyle(theme.text2)
                        if country == selection {
                            Image(systemName: "checkmark").foregroundStyle(theme.accentColor)
                        }
                    }
                }
                .listRowBackground(theme.elev)
            }
            .scrollContentBackground(.hidden)
            .background(ScreenBackground())
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .navigationTitle("Country")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly) } }
        }
    }
}
