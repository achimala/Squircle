import UIKit
import Combine

@MainActor
final class ThreadViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextViewDelegate {
    private let model: SquircleModel
    private let project: AppProject
    private let initialID: String?
    private var subscriptions = Set<AnyCancellable>()
    private var messages: [ChatMessage] = []
    private var opening = true
    private enum Preview { case automatic, hidden, paused(SimulatorTarget), restarting(SimulatorTarget), visible(SimulatorTarget,T3DeviceStream) }
    private var previewState: Preview = .automatic
    private var stream: T3DeviceStream? { if case .visible(_,let stream) = previewState { return stream }; return nil }
    private let home = Theme.glassButton(symbol:"house",identifier:"simulator.home",accessibilityLabel:"Simulator Home")
    private let table = UITableView(frame:.zero,style:.plain)
    private let titleLabel = Theme.label("",Theme.font(.headline,17,.semibold))
    private let statusLabel = Theme.label("",Theme.font(.footnote,12),color:.secondaryLabel,lines:2)
    private let agent = UIButton(type:.system)
    private let device = Theme.glassButton(symbol:"iphone",identifier:"thread.simulator",accessibilityLabel:"Choose simulator")
    private let sendButton = Theme.glassButton(symbol:"arrow.up",prominent:true,identifier:"thread.send",accessibilityLabel:"Send message")
    private let input = UITextView()
    private let body = UIStackView()
    private let preview = UIStackView()
    private let surface = SimulatorSurface()
    private let simulatorStatus = Theme.label("Connecting simulator",Theme.font(.footnote,12),color:.secondaryLabel,lines:2)
    private let requestButton = UIButton(type:.system)
    private var expanded = false
    private var previewHeight: NSLayoutConstraint!

    init(model:SquircleModel,project:AppProject,sessionID:String?) {
        self.model = model; self.project = project; initialID = sessionID
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = Theme.paper
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem(image:UIImage(systemName:"chevron.left"),primaryAction:UIAction { [weak self] _ in self?.navigationController?.dismiss(animated:true) })
        close.accessibilityIdentifier = "thread.close"; close.accessibilityLabel = "Back to threads"
        navigationItem.leftBarButtonItem = close
        table.backgroundColor = .clear; table.separatorStyle = .none; table.keyboardDismissMode = .interactive
        table.dataSource = self; table.delegate = self; table.estimatedRowHeight = 100
        table.register(T3MessageCell.self,forCellReuseIdentifier:"message"); table.accessibilityIdentifier = "thread.messages"
        input.font = Theme.font(.body,17); input.backgroundColor = Theme.codeFill; input.layer.cornerRadius = 18
        input.textContainerInset = UIEdgeInsets(top:12,left:12,bottom:12,right:12); input.delegate = self
        input.accessibilityIdentifier = "thread.input"; input.accessibilityLabel = "Message the coding agent"
        input.heightAnchor.constraint(equalToConstant:66).isActive = true
        agent.titleLabel?.font = Theme.font(.footnote,13,.medium); agent.accessibilityIdentifier = "thread.agent"
        agent.addAction(UIAction { [weak self] _ in self?.chooseAgent() },for:.touchUpInside)
        device.addAction(UIAction { [weak self] _ in self?.chooseDevice() },for:.touchUpInside)
        sendButton.addAction(UIAction { [weak self] _ in self?.send() },for:.touchUpInside)
        let header = UIStackView(arrangedSubviews:[titleLabel,device]); header.spacing = 12; header.alignment = .center
        let choices = UIStackView(arrangedSubviews:[agent,UIView(),statusLabel]); choices.spacing = 10
        let composer = UIStackView(arrangedSubviews:[input,sendButton]); composer.alignment = .bottom; composer.spacing = 10
        home.addAction(UIAction { [weak self] _ in Task { try? await self?.stream?.send(tag:4,payload:.from(["button":"home"])) } },for:.touchUpInside)
        let expand = Theme.glassButton(symbol:"arrow.up.left.and.arrow.down.right",identifier:"simulator.expand",accessibilityLabel:"Expand simulator")
        expand.addAction(UIAction { [weak self] _ in
            guard let self else { return }; expanded.toggle()
            previewHeight.constant = expanded ? max(220,view.bounds.height * 0.60) : 220
            UIView.animate(withDuration:0.3,delay:0,usingSpringWithDamping:0.9,initialSpringVelocity:0) { self.view.layoutIfNeeded() }
        },for:.touchUpInside)
        let hide = Theme.glassButton(symbol:"xmark",identifier:"simulator.close",accessibilityLabel:"Hide simulator")
        hide.addAction(UIAction { [weak self] _ in self?.hidePreview() },for:.touchUpInside)
        let controls = UIStackView(arrangedSubviews:[simulatorStatus,UIView(),home,expand,hide]); controls.spacing = 10; controls.alignment = .center
        preview.axis = .vertical; preview.spacing = 6; preview.addArrangedSubview(surface); preview.addArrangedSubview(controls)
        previewHeight = surface.heightAnchor.constraint(equalToConstant:220); previewHeight.isActive = true
        previewHeight.priority = .defaultHigh
        preview.isHidden = true
        requestButton.titleLabel?.numberOfLines = 0; requestButton.contentHorizontalAlignment = .leading
        requestButton.accessibilityIdentifier = "thread.request"; requestButton.isHidden = true
        requestButton.addAction(UIAction { [weak self] _ in self?.showRequest() },for:.touchUpInside)
        body.axis = .vertical; body.spacing = 8
        for v in [header,choices,preview,requestButton,table,composer] { body.addArrangedSubview(v) }
        body.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(body)
        NSLayoutConstraint.activate([body.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:8),
            body.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),body.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16),
            body.bottomAnchor.constraint(equalTo:view.keyboardLayoutGuide.topAnchor,constant:-8)])
        model.objectWillChange.receive(on:DispatchQueue.main).debounce(for:.milliseconds(60),scheduler:DispatchQueue.main)
            .sink { [weak self] in self?.render() }.store(in:&subscriptions)
        NotificationCenter.default.publisher(for:UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.pausePreview() }.store(in:&subscriptions)
        NotificationCenter.default.publisher(for:UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.reconcilePreview() }.store(in:&subscriptions)
        Task { [weak self] in
            guard let self else { return }; model.selectProject(project)
            if let initialID { await model.selectSession(initialID) } else { await model.createSession(in:project) }
            opening = false; render()
        }
    }
    override func viewDidAppear(_ animated:Bool) {
        super.viewDidAppear(animated); reconcilePreview()
    }
    override func viewDidDisappear(_ animated:Bool) {
        super.viewDidDisappear(animated); pausePreview()
    }
    private func reconcilePreview() {
        guard UIApplication.shared.applicationState == .active,
              view.window != nil, navigationController?.topViewController === self else { return }
        let target: SimulatorTarget?
        switch previewState {
        case .hidden, .visible, .restarting: return
        case .paused(let chosen): target = chosen
        case .automatic:
            target = model.activeDevice.flatMap { SimulatorTarget(deviceID:$0["deviceId"].string,hostID:$0["hostId"].string) }
        }
        guard let target else { return }
        startPreview(target)
    }
    private func render() {
        guard !opening else { titleLabel.text = "Opening thread"; return }
        titleLabel.text = model.sessions.first { $0.id == model.selectedSessionID }?.title ?? "New thread"
        let provider = model.providers.first { $0["instanceId"] == model.modelSelection["instanceId"] }
        agent.setTitle("\(provider?["displayName"].string ?? "Agent") · \(model.modelSelection["model"].string ?? "") ▾",for:.normal)
        agent.isEnabled = !model.isRunning
        statusLabel.text = model.error ?? (model.isRunning ? "Working" : model.connected ? "" : "Reconnecting")
        statusLabel.textColor = model.error == nil ? .secondaryLabel : Theme.failure
        let nearBottom = table.contentSize.height - table.contentOffset.y - table.bounds.height < 100
        if messages != model.messages {
            messages = model.messages; table.reloadData()
            if nearBottom, !messages.isEmpty { table.scrollToRow(at:IndexPath(row:messages.count-1,section:0),at:.bottom,animated:false) }
        }
        sendButton.setImage(UIImage(systemName:model.isRunning ? "stop.fill" : "arrow.up"),for:.normal)
        sendButton.accessibilityLabel = model.isRunning ? "Stop agent" : "Send message"
        requestButton.isHidden = model.requests.isEmpty
        requestButton.setTitle(model.requests.first?["summary"].string ?? "Agent needs your response",for:.normal)
        reconcilePreview()
    }
    private func chooseAgent() {
        let sheet = UIAlertController(title:"Coding agent",message:nil,preferredStyle:.actionSheet)
        for provider in model.providers {
            sheet.addAction(UIAlertAction(title:provider["displayName"].string ?? "Agent",style:.default) { [weak self] _ in self?.chooseModel(provider) })
        }
        sheet.addAction(UIAlertAction(title:"Cancel",style:.cancel)); show(sheet,from:agent)
    }
    private func chooseModel(_ provider:JSONValue) {
        let sheet = UIAlertController(title:provider["displayName"].string,message:nil,preferredStyle:.actionSheet)
        for m in provider["models"].array {
            sheet.addAction(UIAlertAction(title:m["name"].string ?? m["slug"].string,style:.default) { [weak self] _ in
                self?.model.modelSelection = .from(["instanceId":provider["instanceId"].string ?? "","model":m["slug"].string ?? ""])
            })
        }
        sheet.addAction(UIAlertAction(title:"Cancel",style:.cancel)); show(sheet,from:agent)
    }
    private func chooseDevice() {
        let sheet = UIAlertController(title:"Simulator",message:nil,preferredStyle:.actionSheet)
        if case .visible(let target,_) = previewState {
            sheet.message = "Restarting closes this simulator’s running apps. Installed apps and data remain."
            sheet.addAction(UIAlertAction(title:"Restart current simulator",style:.destructive) { [weak self] _ in
                guard let self else { return }
                self.pausePreview(); self.previewState = .restarting(target); self.device.isEnabled = false
                Task {
                    let reopened = await self.model.openDevice(.from(["id":target.deviceID,"hostId":target.hostID]),restart:true)
                    self.previewState = .paused(reopened ?? target); self.device.isEnabled = true; self.reconcilePreview()
                }
            })
        }
        for d in model.devices["devices"].array where d["platform"].string == "ios" && !d["physical"].bool {
            sheet.addAction(UIAlertAction(title:d["name"].string,style:.default) { [weak self] _ in
                Task { guard let self else { return }; if let target = await self.model.openDevice(d) {
                        self.pausePreview(); self.previewState = .paused(target); self.reconcilePreview()
                    }
                }
            })
        }
        sheet.addAction(UIAlertAction(title:"Cancel",style:.cancel)); show(sheet,from:device)
    }
    private func startPreview(_ target:SimulatorTarget) {
        guard let http = model.gateway?.http else { return }
        let stream = T3DeviceStream(http:http,base:model.devices["hubBasePath"].string ?? "/api/device-hub",target:target)
        previewState = .visible(target,stream); surface.stream = stream
        stream.onFrame = { [weak self] in self?.surface.frame($0) }
        stream.onScreen = { [weak self] in self?.surface.screen($0) }
        stream.onStatus = { [weak self] in self?.simulatorStatus.text = $0 ?? "" }
        stream.onInteractive = { [weak self] ready in self?.surface.isUserInteractionEnabled = ready; self?.home.isEnabled = ready }
        preview.isHidden = false; stream.start()
    }
    private func pausePreview() {
        if case .visible(let target,let stream) = previewState { stream.stop(); previewState = .paused(target) }
        surface.stream = nil; preview.isHidden = true
    }
    private func hidePreview() { pausePreview(); previewState = .hidden }

    private func send() {
        if model.isRunning { Task { await model.stop() }; return }
        let text = input.text ?? ""; guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        sendButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }; await model.send(text)
            if model.error == nil { input.text = "" }; sendButton.isEnabled = true
        }
    }
    private func showRequest() {
        guard let r = model.requests.first else { return }
        let p = r["payload"]
        if (r["kind"].string ?? "").contains("user-input") {
            askQuestions(r,questions:p["questions"].array,index:0,answers:[:]); return
        }
        let sheet = UIAlertController(title:r["summary"].string ?? "Approval",message:p["detail"].string ?? p.formatted,preferredStyle:.actionSheet)
        let options = p["options"].array
        if options.isEmpty {
            for (label,decision) in [("Allow once","accept"),("Decline","decline")] {
                sheet.addAction(UIAlertAction(title:label,style:.default) { [weak self] _ in Task { await self?.model.respond(to:r,decision:decision) } })
            }
        } else {
            for option in options {
                sheet.addAction(UIAlertAction(title:option["label"].string,style:.default) { [weak self] _ in Task { await self?.model.respond(to:r,decision:option["decision"].string) } })
            }
        }
        sheet.addAction(UIAlertAction(title:"Later",style:.cancel)); show(sheet,from:requestButton)
    }
    private func askQuestions(_ request:JSONValue,questions:[JSONValue],index:Int,answers:[String:Any]) {
        guard index < questions.count else { Task { await model.respond(to:request,answers:answers) }; return }
        let q = questions[index]; let id = q["id"].string ?? q["header"].string ?? "answer"
        let alert = UIAlertController(title:q["header"].string ?? "Agent question",message:q["question"].string,preferredStyle:.alert)
        alert.addTextField { $0.placeholder = "Your answer" }
        func answer(_ text:String) { var updated = answers; updated[id] = text; askQuestions(request,questions:questions,index:index+1,answers:updated) }
        for option in q["options"].array {
            let label = option["label"].string ?? option.string ?? "Option"
            alert.addAction(UIAlertAction(title:label,style:.default) { _ in answer(option["value"].string ?? label) })
        }
        alert.addAction(UIAlertAction(title:"Send answer",style:.default) { [weak alert] _ in answer(alert?.textFields?.first?.text ?? "") })
        alert.addAction(UIAlertAction(title:"Later",style:.cancel)); present(alert,animated:true)
    }
    private func show(_ sheet:UIAlertController,from source:UIView) {
        sheet.popoverPresentationController?.sourceView = source; sheet.popoverPresentationController?.sourceRect = source.bounds
        present(sheet,animated:true)
    }
    func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { messages.count }
    func tableView(_ tableView:UITableView,cellForRowAt indexPath:IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier:"message",for:indexPath) as! T3MessageCell
        cell.configure(messages[indexPath.row]); return cell
    }
    func tableView(_ tableView:UITableView,didSelectRowAt indexPath:IndexPath) {
        tableView.deselectRow(at:indexPath,animated:true)
        let message = messages[indexPath.row]; guard !message.detail.isEmpty else { return }
        let detail = UIViewController(); detail.title = message.content
        let text = UITextView(); text.backgroundColor = Theme.paper; text.isEditable = false
        text.font = .monospacedSystemFont(ofSize:13,weight:.regular); text.text = message.detail
        text.textContainerInset = UIEdgeInsets(top:20,left:18,bottom:30,right:18)
        detail.view = text; navigationController?.pushViewController(detail,animated:true)
    }
}

private final class T3MessageCell: UITableViewCell {
    private let text = UITextView()
    override init(style:UITableViewCell.CellStyle,reuseIdentifier:String?) {
        super.init(style:style,reuseIdentifier:reuseIdentifier); backgroundColor = .clear; selectionStyle = .none
        text.isEditable = false; text.isScrollEnabled = false; text.backgroundColor = .clear
        text.dataDetectorTypes = [.link]; text.translatesAutoresizingMaskIntoConstraints = false
        text.textContainerInset = UIEdgeInsets(top:10,left:6,bottom:10,right:6)
        contentView.addSubview(text)
        NSLayoutConstraint.activate([text.topAnchor.constraint(equalTo:contentView.topAnchor,constant:5),
            text.bottomAnchor.constraint(equalTo:contentView.bottomAnchor,constant:-5),text.leadingAnchor.constraint(equalTo:contentView.leadingAnchor),
            text.trailingAnchor.constraint(equalTo:contentView.trailingAnchor)])
    }
    required init?(coder:NSCoder) { fatalError() }
    func configure(_ message:ChatMessage) {
        let tool = message.role == "tool"
        text.text = message.content + (tool && !message.detail.isEmpty ? "  ›" : "")
        text.font = Theme.font(tool ? .footnote : .body,tool ? 13 : 17,tool ? .medium : .regular)
        text.textColor = message.failed ? Theme.failure : tool ? .secondaryLabel : .label
        text.backgroundColor = message.role == "user" ? Theme.userBubble : .clear; text.layer.cornerRadius = 16
        text.isUserInteractionEnabled = !tool
        accessibilityIdentifier = "thread.message.\(message.role)"
    }
}
