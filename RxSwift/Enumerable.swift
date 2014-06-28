//
//  Enumerable.swift
//  RxSwift
//
//  Created by Justin Spahr-Summers on 2014-06-25.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

import Foundation

/// A pull-driven stream that executes work when an enumerator is attached.
class Enumerable<T>: Stream<T> {
	typealias Enumerator = Event<T> -> ()

	@final let _enumerate: Enumerator -> Disposable?
	init(enumerate: Enumerator -> Disposable?) {
		_enumerate = enumerate
	}

	@final class func empty() -> Enumerable<T> {
		return Enumerable { send in
			send(.Completed)
			return nil
		}
	}

	@final override class func unit(value: T) -> Enumerable<T> {
		return Enumerable { send in
			send(.Next(Box(value)))
			send(.Completed)
			return nil
		}
	}

	@final class func error(error: NSError) -> Enumerable<T> {
		return Enumerable { send in
			send(.Error(error))
			return nil
		}
	}

	@final class func never() -> Enumerable<T> {
		return Enumerable { _ in nil }
	}

	@final func enumerate(enumerator: Enumerator) -> Disposable? {
		return _enumerate(enumerator)
	}

	@final override func mapAccumulate<S, U>(initialState: S, _ f: (S, T) -> (S?, U)) -> Enumerable<U> {
		return Enumerable<U> { send in
			let state = Atomic(initialState)

			return self.enumerate { event in
				switch event {
				case let .Next(value):
					let (maybeState, newValue) = f(state, value)
					send(.Next(Box(newValue)))

					if let s = maybeState {
						state.value = s
					} else {
						send(.Completed)
					}

				case let .Error(error):
					send(.Error(error))

				case let .Completed:
					send(.Completed)
				}
			}
		}
	}

	@final func removeNil<U>(evidence: Enumerable<T> -> Enumerable<U?>) -> Enumerable<U> {
		return Enumerable<U> { send in
			return evidence(self).enumerate { event in
				switch event {
				case let .Next(maybeValue):
					if let value = maybeValue.value {
						send(.Next(Box(value)))
					}

				case let .Error(error):
					send(.Error(error))

				case let .Completed:
					send(.Completed)
				}
			}
		}
	}

	@final override func merge<U>(evidence: Stream<T> -> Stream<Stream<U>>) -> Enumerable<U> {
		return Enumerable<U> { send in
			let disposable = CompositeDisposable()
			let inFlight = Atomic(1)

			func decrementInFlight() {
				let orig = inFlight.modify { $0 - 1 }
				if orig == 1 {
					send(.Completed)
				}
			}

			let selfDisposable = (evidence(self) as Enumerable<Stream<U>>).enumerate { event in
				switch event {
				case let .Next(stream):
					let streamDisposable = SerialDisposable()
					disposable.addDisposable(streamDisposable)

					streamDisposable.innerDisposable = (stream.value as Enumerable<U>).enumerate { event in
						if event.isTerminating {
							disposable.removeDisposable(streamDisposable)
						}

						switch event {
						case let .Completed:
							decrementInFlight()

						default:
							send(event)
						}
					}

				case let .Error(error):
					send(.Error(error))

				case let .Completed:
					decrementInFlight()
				}
			}

			disposable.addDisposable(selfDisposable)
			return disposable
		}
	}

	@final override func switchToLatest<U>(evidence: Stream<T> -> Stream<Stream<U>>) -> Enumerable<U> {
		return Enumerable<U> { send in
			let selfCompleted = Atomic(false)
			let latestCompleted = Atomic(false)

			func completeIfNecessary() {
				if selfCompleted.value && latestCompleted.value {
					send(.Completed)
				}
			}

			let compositeDisposable = CompositeDisposable()

			let latestDisposable = SerialDisposable()
			compositeDisposable.addDisposable(latestDisposable)

			let selfDisposable = (evidence(self) as Enumerable<Stream<U>>).enumerate { event in
				switch event {
				case let .Next(stream):
					latestDisposable.innerDisposable = nil
					latestDisposable.innerDisposable = (stream.value as Enumerable<U>).enumerate { innerEvent in
						switch innerEvent {
						case let .Completed:
							latestCompleted.value = true
							completeIfNecessary()

						default:
							send(innerEvent)
						}
					}

				case let .Error(error):
					send(.Error(error))

				case let .Completed:
					selfCompleted.value = true
					completeIfNecessary()
				}
			}

			compositeDisposable.addDisposable(selfDisposable)
			return compositeDisposable
		}
	}

	@final override func map<U>(f: T -> U) -> Enumerable<U> {
		return super.map(f) as Enumerable<U>
	}

	@final override func scan<U>(initialValue: U, _ f: (U, T) -> U) -> Enumerable<U> {
		return super.scan(initialValue, f) as Enumerable<U>
	}

	@final override func take(count: Int) -> Enumerable<T> {
		if count == 0 {
			return .empty()
		}

		return super.take(count) as Enumerable<T>
	}

	@final override func takeWhileThenNil(pred: T -> Bool) -> Enumerable<T?> {
		return super.takeWhileThenNil(pred) as Enumerable<T?>
	}

	@final func takeWhile(pred: T -> Bool) -> Enumerable<T> {
		return takeWhileThenNil(pred).removeNil(identity)
	}

	@final override func combinePrevious(initialValue: T) -> Enumerable<(T, T)> {
		return super.combinePrevious(initialValue) as Enumerable<(T, T)>
	}

	@final override func skipAsNil(count: Int) -> Enumerable<T?> {
		return super.skipAsNil(count) as Enumerable<T?>
	}

	@final func skip(count: Int) -> Enumerable<T> {
		return skipAsNil(count).removeNil(identity)
	}

	@final override func skipAsNilWhile(pred: T -> Bool) -> Enumerable<T?> {
		return super.skipAsNilWhile(pred) as Enumerable<T?>
	}

	@final func skipWhile(pred: T -> Bool) -> Enumerable<T> {
		return skipAsNilWhile(pred).removeNil(identity)
	}

	@final func first() -> Event<T> {
		let cond = NSCondition()
		cond.name = "com.github.ReactiveCocoa.Enumerable.first"

		var event: Event<T>? = nil
		take(1).enumerate { ev in
			withLock(cond) {
				event = ev
				cond.signal()
			}
		}

		return withLock(cond) {
			while event == nil {
				cond.wait()
			}

			return event!
		}
	}

	@final func waitUntilCompleted() -> Event<()> {
		return ignoreValues().first()
	}

	@final func bindToProperty(property: ObservableProperty<T>) -> Disposable? {
		return self.enumerate { event in
			switch event {
			case let .Next(value):
				property.current = value

			case let .Error(error):
				assert(false)

			default:
				break
			}
		}
	}

	@final func filter(pred: T -> Bool) -> Enumerable<T> {
		return self
			.map { value -> Enumerable<T> in
				if pred(value) {
					return .unit(value)
				} else {
					return .empty()
				}
			}
			.merge(identity)
	}

	@final func skipRepeats<U: Equatable>(evidence: Stream<T> -> Stream<U>) -> Enumerable<U> {
		return (evidence(self) as Enumerable<U>)
			.mapAccumulate(nil) { (maybePrevious: U?, current: U) -> (U??, Enumerable<U>) in
				if let previous = maybePrevious {
					if current == previous {
						return (current, .empty())
					}
				}

				return (current, .unit(current))
			}
			.merge(identity)
	}

	@final func materialize() -> Enumerable<Event<T>> {
		return Enumerable<Event<T>> { send in
			return self.enumerate { event in
				send(.Next(Box(event)))

				if event.isTerminating {
					send(.Completed)
				}
			}
		}
	}

	@final func dematerialize<U>(evidence: Enumerable<T> -> Enumerable<Event<U>>) -> Enumerable<U> {
		return Enumerable<U> { send in
			return evidence(self).enumerate { event in
				switch event {
				case let .Next(innerEvent):
					send(innerEvent)

				case let .Error(error):
					send(.Error(error))

				case let .Completed:
					send(.Completed)
				}
			}
		}
	}

	@final func catch(f: NSError -> Enumerable<T>) -> Enumerable<T> {
		return Enumerable { send in
			let serialDisposable = SerialDisposable()

			serialDisposable.innerDisposable = self.enumerate { event in
				switch event {
				case let .Error(error):
					let newStream = f(error)
					serialDisposable.innerDisposable = newStream.enumerate(send)

				default:
					send(event)
				}
			}

			return serialDisposable
		}
	}

	@final func ignoreValues() -> Enumerable<()> {
		return Enumerable<()> { send in
			return self.enumerate { event in
				switch event {
				case let .Next(value):
					break

				case let .Error(error):
					send(.Error(error))

				case let .Completed:
					send(.Completed)
				}
			}
		}
	}

	@final func doEvent(action: Event<T> -> ()) -> Enumerable<T> {
		return Enumerable { send in
			return self.enumerate { event in
				action(event)
				send(event)
			}
		}
	}

	@final func doDisposed(action: () -> ()) -> Enumerable<T> {
		return Enumerable { send in
			let disposable = CompositeDisposable()
			disposable.addDisposable(ActionDisposable(action))
			disposable.addDisposable(self.enumerate(send))
			return disposable
		}
	}

	@final func enumerateOn(scheduler: Scheduler) -> Enumerable<T> {
		return Enumerable { send in
			return self.enumerate { event in
				scheduler.schedule { send(event) }
				return ()
			}
		}
	}

	@final func concat(stream: Enumerable<T>) -> Enumerable<T> {
		return Enumerable { send in
			let serialDisposable = SerialDisposable()

			serialDisposable.innerDisposable = self.enumerate { event in
				switch event {
				case let .Completed:
					serialDisposable.innerDisposable = stream.enumerate(send)

				default:
					send(event)
				}
			}

			return serialDisposable
		}
	}

	@final func takeLast(count: Int) -> Enumerable<T> {
		return Enumerable { send in
			let values: Atomic<T[]> = Atomic([])

			return self.enumerate { event in
				switch event {
				case let .Next(value):
					values.modify { (var arr) in
						arr.append(value)
						while arr.count > count {
							arr.removeAtIndex(0)
						}

						return arr
					}

				case let .Completed:
					for v in values.value {
						send(.Next(Box(v)))
					}

					send(.Completed)

				default:
					send(event)
				}
			}
		}
	}

	@final func aggregate<U>(initialValue: U, _ f: (U, T) -> U) -> Enumerable<U> {
		let scanned = scan(initialValue, f)

		return Enumerable<U>.unit(initialValue)
			.concat(scanned)
			.takeLast(1)
	}

	@final func collect() -> Enumerable<SequenceOf<T>> {
		return self
			.aggregate([]) { (var values, current) in
				values.append(current)
				return values
			}
			.map { SequenceOf($0) }
	}

	@final func delay(interval: NSTimeInterval, onScheduler scheduler: Scheduler) -> Enumerable<T> {
		return Enumerable { send in
			return self.enumerate { event in
				switch event {
				case let .Error:
					scheduler.schedule { send(event) }

				default:
					scheduler.scheduleAfter(NSDate(timeIntervalSinceNow: interval)) { send(event) }
				}
			}
		}
	}

	/*
	@final func timeout(interval: NSTimeInterval, onScheduler: Scheduler) -> Enumerable<T>
	*/
}
