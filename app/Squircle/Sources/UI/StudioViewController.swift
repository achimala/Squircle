import UIKit
import Combine

final class StudioViewController: UIViewController, UIScrollViewDelegate {
    let model: SquircleModel
    private let carousel = UIScrollView()
    private let chrome = UIView()
    private let pages = UIPageControl()
    private let add = GlassButton(symbol: "plus", label: "Create app")
    private let status = GlassButton(symbol: "wifi.slash", label: "Connection status")
    private var subscriptions = Set<AnyCancellable>()
    private var heroes: [String: ProjectHero] = [:]
    private var projects: [AppProject] = []
    private var selectedID: String?
    private var pendingOpenID: String?
    private var workspaceTransition: WorkspaceTransition?
    private weak var gestureProject: ProjectViewController?
    private var laidOutSize = CGSize.zero
    private var isPaging = false
    private var deferredRender = false
    private var pitch: CGFloat { max(1, view.bounds.width * 0.58) }
    private var selectedIndex: Int { projects.firstIndex { $0.id == selectedID } ?? 0 }

    init(model: SquircleModel) {
        self.model = model; selectedID = model.selectedProjectID
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Studio.canvas; view.clipsToBounds = true
        carousel.delegate = self; carousel.showsHorizontalScrollIndicator = false
        carousel.showsVerticalScrollIndicator = false; carousel.decelerationRate = .fast
        carousel.contentInsetAdjustmentBehavior = .never; carousel.alwaysBounceHorizontal = true
        carousel.accessibilityIdentifier = "app.picker"
        view.addSubview(carousel); view.addSubview(chrome); view.addSubview(pages)
        let mark = AppGlyphView(); mark.filled = false; mark.tag = 1
        chrome.addSubview(mark); chrome.addSubview(add); chrome.addSubview(status)
        add.accessibilityIdentifier = "project.add"
        add.addAction(UIAction { [weak self] _ in self?.createProject() }, for: .touchUpInside)
        status.addAction(UIAction { [weak self] _ in self?.showConnection() }, for: .touchUpInside)
        pages.pageIndicatorTintColor = Studio.ink.withAlphaComponent(0.13)
        pages.currentPageIndicatorTintColor = Studio.ink
        pages.hidesForSinglePage = true
        pages.addAction(UIAction { [weak self] _ in self?.selectPage() }, for: .valueChanged)
        model.objectWillChange.receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setWorkspaceProgress(0, selectedID: selectedID ?? "")
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        place(chrome, in: CGRect(x: 24, y: safe.top + 8, width: view.bounds.width - 48, height: 48))
        chrome.viewWithTag(1)?.frame = CGRect(x: -6, y: 4, width: 40, height: 40)
        add.frame = CGRect(x: chrome.bounds.width - 48, y: 0, width: 48, height: 48)
        status.frame = CGRect(x: chrome.bounds.width - 105, y: 2, width: 44, height: 44)
        carousel.frame = CGRect(x: 0, y: safe.top + 66, width: view.bounds.width,
                                height: max(250, view.bounds.height - safe.top - safe.bottom - 120))
        place(pages, in: CGRect(x: 20, y: view.bounds.height - safe.bottom - 48, width: view.bounds.width - 40, height: 32))
        if laidOutSize != carousel.bounds.size {
            laidOutSize = carousel.bounds.size
            layoutHeroes(); carousel.contentOffset.x = CGFloat(selectedIndex) * pitch
            updatePicker()
        }
    }

    private func place(_ child: UIView, in frame: CGRect) {
        // Layout owns base geometry; the transition owns the transform.
        child.bounds = CGRect(origin: .zero, size: frame.size)
        child.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    private func render() {
        guard presentedViewController == nil else { return }
        let next = model.projects
        let changed = next.map(\.id) != projects.map(\.id)
        if changed && (carousel.isTracking || carousel.isDecelerating || isPaging) {
            deferredRender = true
            for project in next { heroes[project.id]?.update(project: project) }
            return
        }
        projects = next
        if !projects.contains(where: { $0.id == selectedID }) { selectedID = projects.first?.id }
        let ids = Set(projects.map(\.id))
        for id in Array(heroes.keys) where !ids.contains(id) { heroes.removeValue(forKey: id)?.removeFromSuperview() }
        for project in projects {
            if let hero = heroes[project.id] { hero.update(project: project) }
            else {
                let hero = ProjectHero(model: model, project: project)
                hero.onPage = { [weak self] direction in self?.moveSelection(direction) }
                hero.addAction(UIAction { [weak self] _ in self?.choose(project.id) }, for: .touchUpInside)
                heroes[project.id] = hero; carousel.addSubview(hero)
            }
        }
        status.isHidden = model.connected && model.error == nil
        pages.numberOfPages = projects.count
        if changed {
            layoutHeroes(); carousel.contentOffset.x = CGFloat(selectedIndex) * pitch
        }
        updatePicker()
    }

    private func layoutHeroes() {
        let width = carousel.bounds.width, height = carousel.bounds.height
        carousel.contentSize = CGSize(width: width + CGFloat(max(0, projects.count - 1)) * pitch, height: height)
        for (index, project) in projects.enumerated() {
            if let hero = heroes[project.id] {
                place(hero, in: CGRect(x: CGFloat(index) * pitch, y: 0, width: width, height: height))
            }
        }
    }

    private func updatePicker() {
        guard !projects.isEmpty else { return }
        let position = carousel.contentOffset.x / pitch
        let nearest = max(0, min(projects.count - 1, Int(position.rounded())))
        pages.currentPage = nearest
        if let center = heroes[projects[nearest].id] { carousel.bringSubviewToFront(center) }
        for (index, project) in projects.enumerated() {
            guard let hero = heroes[project.id] else { continue }
            let offset = CGFloat(index) - position
            hero.setPickerOffset(offset)
            hero.phone.setAnimating((carousel.isDragging || carousel.isDecelerating || isPaging) && abs(offset) < 1.7)
            hero.layer.zPosition = 10 - abs(offset)
            hero.setSelected(index == nearest)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updatePicker() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pendingOpenID = nil; isPaging = false
        heroes.values.forEach { $0.phone.setAnimating(true) }
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let index = max(0, min(projects.count - 1, Int((targetContentOffset.pointee.x / pitch).rounded())))
        targetContentOffset.pointee.x = CGFloat(index) * pitch
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settle() } }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        settle()
        if let id = pendingOpenID { pendingOpenID = nil; open(id) }
    }
    private func settle() {
        guard !projects.isEmpty else { return }
        isPaging = false
        let index = max(0, min(projects.count - 1, Int((carousel.contentOffset.x / pitch).rounded())))
        if selectedID != projects[index].id { Studio.haptic() }
        selectedID = projects[index].id
        heroes.values.forEach { $0.phone.setAnimating(false) }
        updatePicker()
        if deferredRender { deferredRender = false; render() }
    }
    private func moveSelection(_ direction: Int) {
        guard !projects.isEmpty else { return }
        let index = max(0, min(projects.count - 1, selectedIndex + direction))
        pages.currentPage = index; selectPage()
    }
    private func selectPage() {
        pendingOpenID = nil
        let target = CGFloat(pages.currentPage) * pitch
        guard abs(carousel.contentOffset.x - target) > 1 else { settle(); return }
        isPaging = true
        heroes.values.forEach { $0.phone.setAnimating(true) }
        carousel.setContentOffset(CGPoint(x: target, y: 0), animated: true)
    }
    private func choose(_ id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let target = CGFloat(index) * pitch
        if abs(carousel.contentOffset.x - target) > 1 {
            pendingOpenID = id; isPaging = true; heroes.values.forEach { $0.phone.setAnimating(true) }
            carousel.setContentOffset(CGPoint(x: target, y: 0), animated: true)
        } else { selectedID = id; open(id) }
    }

    private func open(_ id: String) {
        guard presentedViewController == nil, let project = projects.first(where: { $0.id == id }) else { return }
        Studio.haptic(); model.selectProject(project)
        let detail = ProjectViewController(model: model, project: project)
        let transition = WorkspaceTransition(source: heroes[id], studio: self)
        workspaceTransition = transition
        detail.transitioningDelegate = transition; detail.modalPresentationStyle = .overFullScreen
        detail.onBack = { [weak detail] in detail?.dismiss(animated: true) }
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(swipeBack(_:)))
        edge.edges = .left; detail.view.addGestureRecognizer(edge)
        present(detail, animated: true)
    }

    @objc private func swipeBack(_ gesture: UIScreenEdgePanGestureRecognizer) {
        if gesture.state == .began {
            guard let detail = presentedViewController as? ProjectViewController,
                  detail.presentedViewController == nil else { return }
            gestureProject = detail
        }
        guard let detail = gestureProject, let transition = workspaceTransition else { return }
        let progress = min(1, max(0, gesture.translation(in: detail.view).x / view.bounds.width))
        #if DEBUG
        if gesture.state != .changed {
            MotionAudit.shared.note("edge", values: ["state": gesture.state.rawValue, "progress": progress, "velocity": gesture.velocity(in: detail.view).x])
        }
        #endif
        switch gesture.state {
        case .began:
            transition.beginInteractiveDismissal(); detail.dismiss(animated: true)
        case .changed: transition.updateInteractiveDismissal(progress)
        case .ended:
            if progress > 0.35 || gesture.velocity(in: detail.view).x > 500 { transition.finishInteractiveDismissal() }
            else { transition.cancelInteractiveDismissal() }
            gestureProject = nil
        case .cancelled, .failed: transition.cancelInteractiveDismissal(); gestureProject = nil
        default: break
        }
    }

    // These are the real picker views. The workspace transition moves them out
    // of the way while the selected device and title travel into the header.
    func setWorkspaceProgress(_ progress: CGFloat, selectedID: String) {
        chrome.transform = CGAffineTransform(translationX: 0, y: -160 * progress)
        pages.transform = CGAffineTransform(translationX: 0, y: 120 * progress)
        let index = projects.firstIndex { $0.id == selectedID } ?? 0
        for (position, project) in projects.enumerated() {
            guard project.id != selectedID else { continue }
            heroes[project.id]?.transform = CGAffineTransform(translationX: (position < index ? -1 : 1) * view.bounds.width * progress, y: 0)
        }
    }

    private func createProject() {
        let importer = AppImportNavigationController(model: model)
        importer.onImport = { [weak self, weak importer] project in
            importer?.dismiss(animated: true) {
                guard let self else { return }
                self.selectedID = project.id
                self.render()
                self.choose(project.id)
            }
        }
        present(importer, animated: true)
    }
    private func showConnection() {
        let alert = UIAlertController(title: model.connected ? "Connected" : "Mac offline", message: model.error, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in Task { await self?.model.refresh() } })
        alert.addAction(UIAlertAction(title: "Close", style: .cancel)); present(alert, animated: true)
    }
}
