//
//  Date+stripTime.swift
//  VexSign
//
//  Created by VexSign Contributors on 21.06.2025.
//

import Foundation.NSDate

extension Date {
	public func stripTime() -> Date {
		Calendar.current.startOfDay(for: self)
	}
}
