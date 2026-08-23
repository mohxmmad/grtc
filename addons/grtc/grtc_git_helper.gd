tool
extends Reference

func _git_args(project_path, args):
	var full_args = PoolStringArray(["-C", project_path])
	for arg in args:
		full_args.append(str(arg))
	return full_args

func _run_git(project_path, args):
	var output = []
	var code = OS.execute("git", _git_args(project_path, args), true, output)
	return {"code": code, "output": output}

func _run_git_with_identity(project_path, args, author_name, author_email):
	var wrapped = ["-c", "user.name=%s" % author_name, "-c", "user.email=%s" % author_email]
	for arg in args:
		wrapped.append(str(arg))
	return _run_git(project_path, wrapped)

func _repo_exists(project_path):
	return Directory.new().dir_exists(project_path + "/.git")

func init_repository(project_path):
	if _repo_exists(project_path):
		return {"code": 0, "output": ["Repository already initialized"]}
	return _run_git(project_path, ["init"])

func ensure_remote(project_path, remote_name, remote_url):
	var result = _run_git(project_path, ["remote", "get-url", remote_name])
	if result.code == 0 and result.output.size() > 0:
		if str(result.output[0]).strip_edges() == remote_url:
			return {"code": 0, "output": ["Remote already configured"]}
		return _run_git(project_path, ["remote", "set-url", remote_name, remote_url])
	return _run_git(project_path, ["remote", "add", remote_name, remote_url])

func get_remote_url(project_path, remote_name):
	var result = _run_git(project_path, ["remote", "get-url", remote_name])
	if result.code != 0 or result.output.size() == 0:
		return ""
	return str(result.output[0]).strip_edges()

func checkout_main(project_path):
	return _run_git(project_path, ["checkout", "-B", "main"])

func stage_all(project_path):
	return _run_git(project_path, ["add", "-A"])

func commit(project_path, message, author_name, author_email):
	return _run_git_with_identity(project_path, ["commit", "-m", message], author_name, author_email)

func push(project_path, remote_name, branch_name, username, token):
	var auth_remote = _authenticated_url(remote_name, token)
	return _run_git(project_path, ["push", auth_remote, branch_name])

func pull(project_path, remote_name, branch_name, username, token):
	var auth_remote = _authenticated_url(remote_name, token)
	return _run_git(project_path, ["pull", auth_remote, branch_name])

func execute_full_workflow(project_path, repo_url, author_name, author_email, token, commit_message):
	if repo_url == "":
		repo_url = get_remote_url(project_path, "origin")
	if repo_url == "":
		return {"code": 1, "output": ["origin remote not found"]}

	var init_result = init_repository(project_path)
	if init_result.get("code", 0) != 0:
		return init_result

	var remote_result = ensure_remote(project_path, "origin", repo_url)
	if remote_result.get("code", 0) != 0:
		return remote_result

	var branch_result = checkout_main(project_path)
	if branch_result.get("code", 0) != 0:
		return branch_result

	var stage_result = stage_all(project_path)
	if stage_result.get("code", 0) != 0:
		return stage_result

	var commit_result = commit(project_path, commit_message, author_name, author_email)
	var commit_code = commit_result.get("code", 0)
	if commit_code != 0 and commit_code != 1:
		return commit_result

	return push(project_path, repo_url, "main", author_name, token)

func _authenticated_url(remote_url, token):
	if remote_url.begins_with("https://github.com/"):
		return remote_url.replace("https://github.com/", "https://x-access-token:%s@github.com/" % token)
	return remote_url
