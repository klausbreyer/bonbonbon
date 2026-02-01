deploy:
	rsync -avz --exclude '_build' --exclude 'deps' --exclude '.git' --exclude '.elixir_ls' . pi@10.0.0.8:~/bonbonbon/
