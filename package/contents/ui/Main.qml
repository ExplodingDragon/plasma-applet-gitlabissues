import QtQuick 2.0
import QtQuick.Layouts 1.1
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.components 2.0 as PlasmaComponents

import "lib"
import "lib/Async.js" as Async
import "lib/Requests.js" as Requests

Item {
	id: widget

	Logger {
		id: logger
		name: 'gitlabissues'
		// showDebug: true
	}

	Plasmoid.backgroundHints: (typeof PlasmaCore.Types.ConfigurableBackground !== "undefined"
		? PlasmaCore.Types.DefaultBackground | PlasmaCore.Types.ConfigurableBackground
		: plasmoid.configuration.showBackground ? PlasmaCore.Types.DefaultBackground : PlasmaCore.Types.NoBackground
	)
	Plasmoid.hideOnWindowDeactivate: !plasmoid.userConfiguring

	readonly property int updateIntervalInMillis: plasmoid.configuration.updateIntervalInMinutes * 60 * 1000
	readonly property var repoStringRegex: /^(((\w+):\/\/)([^\/]+)(\/))?([^\/]+)(\/)([^\/]+)$/
	readonly property var repoStringList: {
		var out = []
		var skipped = []
		var arr = plasmoid.configuration.repoList
		for (var i = 0; i < arr.length; i++) {
			var repoString = arr[i]
			repoString = repoString.trim()
							out.push(repoString)

			// if (repoString.match(repoStringRegex)) {
			// 	out.push(repoString)
			// } else if (repoString.trim() == '') { // Empty str
			// 	// Skip
			// } else {
			// 	skipped.push(repoString)
			// }
		}
		repoStringSkipped = skipped
		return out
	}
	property var repoStringSkipped: []

	property string errorMessage: ''

	property var issuesModel: []

	Octicons { id: octicons }

	LocalDb {
		id: localDb
		name: plasmoid.pluginName
		version: "1" // DB version, not Widget version
		showDebug: logger.showDebug
	}

	Plasmoid.icon: Plasmoid.compactRepresentationItem ? Plasmoid.compactRepresentationItem.iconSource : ''
	Plasmoid.compactRepresentation: CompactRepresentation {}
	Plasmoid.activationTogglesExpanded: true

	Plasmoid.fullRepresentation: FullRepresentation {}

	function formatUrl(repoString, args) {
		var isLocalFile = repoString.indexOf('file://') >= 0
		if (isLocalFile) { // Testing
			return repoString
		} else {
			var baseUrl = 'https://invent.kde.org'
			var repoPath = repoString // Without leading slash (Eg: User/Repo)

			var hasDomain = repoString.indexOf('://') >= 0
			if (hasDomain) { // Eg: https://domain.com/User/Repo
				var start = repoString.indexOf('://') + '://'.length
				var end = repoString.indexOf('/', start)
				baseUrl = repoString.substr(0, end)
				repoPath = repoString.substr(end + '/'.length)
				logger.debug(repoString, start, end, baseUrl, repoPath)
			}

			var url = baseUrl + '/api/v4'

			if (repoPath.indexOf('groups/') == 0) {
				repoPath = repoPath.substr('groups/'.length)
				url += '/groups/' + encodeURIComponent(repoPath)
			} else { // Project
				url += '/projects/' + encodeURIComponent(repoPath)
			}

			if (args.mergeRequests) {
				url += '/merge_requests'
			} else {
				url += '/issues'
			}

			var params = Object.assign({}, args) // shallow copy
			delete params['mergeRequests']
			logger.debugJSON('params', params)
			if (Object.keys(args).length >= 1) {
				url += '?' + Requests.encodeParams(args)
			}
			logger.debug('fetchIssues.url', url)
			return url
		}
	}

	function fetchIssues(repoString, args, callback) {
		logger.debugJSON('fetchIssues', repoString, args)

		var isLocalFile = repoString.indexOf('file://') >= 0

		// We already generated the url when creating the cacheKey.
		// var url = formatUrl(repoString, args)
		var url = args.url
		Requests.getJSON({
			url: url
		}, function(err, data, xhr){
			logger.debug('fetchIssues.response.url', url)
			logger.debug('fetchIssues.response.err', xhr.status, err)
			logger.debugJSON('fetchIssues.response.data.length', data && data.length)
			// logger.debugJSON('fetchIssues.response.data', data)

			// GitLab Errors:
			// https://docs.gitlab.com/ee/api/README.html#status-codes

			if (xhr.status == 0 && isLocalFile) {
				callback(null, data) // We get HTTP 0 error for a local file, ignore it.
			} else if (xhr.status == 404 && err) {
				// 404 Not Found
				var prettyErr = i18n("Repo '%1' not found.", repoString)
				callback(prettyErr, data)
			} else { // Okay response / Unknown error
				callback(err, data)
			}
		})
	}

	function hasExpired(dt, ttl) {
		var now = new Date()
		var diff = now.getTime() - dt.getTime()
		logger.debug('now:', now.getTime(), now)
		logger.debug('dt: ', dt.getTime(), dt)
		logger.debug('(diff-ttl):', diff, '-', ttl, '=', (diff-ttl), '(diff >= ttl):', diff >= ttl)
		return diff >= ttl
	}

	function getIssueList(repoString, args, callback) {
		logger.debugJSON('getIssueList', repoString, args)
		args.url = formatUrl(repoString, args)
		var cacheKey = args.url
		localDb.getJSON(cacheKey, function(err, data, row){
			logger.debug('getJSON', repoString, data)

			var shouldUpdate = true
			if (data) {
				// Can we assume the timestamp is always UTC?
				// The 'Z' parses the timestamp in UTC.
				// Maybe check the length of the string?
				var rowUpdatedAt = new Date(row.updated_at + 'Z')
				var ttl = widget.updateIntervalInMillis
				shouldUpdate = hasExpired(rowUpdatedAt, ttl)
			}
			logger.debug('shouldUpdate', shouldUpdate)

			if (shouldUpdate) {
				fetchIssues(repoString, args, function(err, data) {
					if (err) {
						logger.debug('getIssueList.err', err)
						callback(err, data)
					} else {
						localDb.setJSON(cacheKey, data, function(err){
							logger.debug('setJSON', repoString)
							callback(err, data)
						})
					}
				})
			} else {
				callback(err, data)
			}
		})
	}

	function deleteCache(callback) {
		localDb.deleteAll(callback)
	}

	function deleteCacheAndReload() {
		logger.debug('deleteCacheAndReload')
		deleteCache(function() {
			debouncedUpdateIssuesModel.restart()
		})
	}

	function updateIssuesModel() {
		logger.debug('updateIssuesModel')

		// Reset error message.
		widget.errorMessage = ''

		if (repoStringSkipped.length >= 1) {
			var validFormat = 'https://invent.kde.org/' + i18n("User/Repo")
			var prettyErr = i18n("Repo '%1' skipped, uses invalid format. Please use '%2'.", repoStringSkipped[0], validFormat)
			widget.errorMessage = prettyErr
		}

		var tasks = []
		for (var i = 0; i < repoStringList.length; i++) {
			var repoString = repoStringList[i]
			var task = getIssueList.bind(null, repoString, {
				state: plasmoid.configuration.issueState,
				order_by: plasmoid.configuration.issueSort,
				sort: plasmoid.configuration.issueSortDirection,
				search: plasmoid.configuration.issueSearch,
				labels: plasmoid.configuration.issueLabels,
				mergeRequests: false,
			})
			tasks.push(task)

			var task = getIssueList.bind(null, repoString, {
				state: plasmoid.configuration.issueState,
				order_by: plasmoid.configuration.issueSort,
				sort: plasmoid.configuration.issueSortDirection,
				search: plasmoid.configuration.issueSearch,
				labels: plasmoid.configuration.issueLabels,
				mergeRequests: true,
			})
			tasks.push(task)
		}

		Async.parallel(tasks, function(err, results){
			logger.debug('Async.parallel.done', err, results && results.length)
			if (err) {
				widget.errorMessage = err
			} else {
				// logger.debugJSON(results)
				parseResults(results)
			}
		})
	}

	function issueCreatedDate(issue) {
		return new Date(issue.created_at).valueOf()
	}
	function issueUpdatedDate(issue) {
		return new Date(issue.updated_at).valueOf()
	}
	function concatLists(arr) {
		if (arr.length >= 2) {
			return Array.prototype.concat.apply(arr[0], arr.slice(1))
		} else if (arr.length == 1) {
			return arr[0]
		} else {
			return []
		}
	}
	function parseResults(results) {
		// Concat all issue lists
		var issues = concatLists(results)
		
		// Sort issues by creation date descending
		if (plasmoid.configuration.issueSort == 'created_at') {
			issues = issues.sort(function(a, b){ return issueCreatedDate(a) - issueCreatedDate(b) })
		} else if (plasmoid.configuration.issueSort == 'updated_at') {
			issues = issues.sort(function(a, b){ return issueUpdatedDate(a) - issueUpdatedDate(b) })
		}

		if (plasmoid.configuration.issueSortDirection == 'desc') {
			issues.reverse()
		}

		issuesModel = issues
	}

	Timer {
		id: debouncedUpdateIssuesModel
		interval: 400
		onTriggered: {
			logger.debug('debouncedUpdateIssuesModel.onTriggered')
			widget.updateIssuesModel()
		}
	}
	Timer {
		id: updateModelTimer
		running: true
		repeat: true
		interval: widget.updateIntervalInMillis
		onTriggered: {
			logger.debug('updateModelTimer.onTriggered')
			debouncedUpdateIssuesModel.restart()
		}
	}

	Connections {
		target: plasmoid.configuration
		onRepoListChanged: debouncedUpdateIssuesModel.restart()
		onIssueStateChanged: deleteCacheAndReload()
		onIssueSortChanged: deleteCacheAndReload()
		onIssueSortDirectionChanged: deleteCacheAndReload()
		onIssueSearchChanged: debouncedUpdateIssuesModel.restart()
		onIssueLabelsChanged: debouncedUpdateIssuesModel.restart()
	}

	function action_refresh() {
		deleteCacheAndReload()
	}

	Component.onCompleted: {
		plasmoid.setAction("refresh", i18n("Refresh"), "view-refresh")

		localDb.initDb(function(err){
			updateIssuesModel()
		})

		// plasmoid.action("configure").trigger() // Uncomment to test config window
	}
}
