class PostsController < ApplicationController
  before_action :confirm_logged_in
  before_action :set_post, only: [:show, :edit, :update, :destroy]
  protect_from_forgery with: :exception

  # GET /posts
  # GET /posts.json
  def index
    if current_user.admin?
      @posts = Post.all
    else
      if current_user.id != params[:user_id]
        @user = User.find_by(id: params[:user_id])
        @posts = @user.posts
      else
        @posts = current_user.posts.all
      end
    end
  end

  # GET /posts/1
  # GET /posts/1.json
  def show
  end

  def recent
    @posts = Post.order(created_at: :desc).limit(5)
  end

  def search
    # http://localhost:3000/posts/search?search_term=t%25%27%3Bselect%20*%20from%20users%3B%20--
    if current_user.admin?
      @search_results = Post.where("posts.content::text LIKE '%#{params[:search_term]}%'")
    else
      @search_results = Post.where("posts.content::text LIKE '%#{params[:search_term]}%' AND posts.public=true")
    end
  end

  # GET /posts/new
  def new
    @post = current_user.posts.new
  end

  # GET /posts/1/edit
  def edit
  end

  # POST /posts
  # POST /posts.json
  def create
    @post = current_user.posts.new(post_params)

    respond_to do |format|
      if @post.save
        format.html { redirect_to @post, notice: 'Post was successfully created.' }
        format.json { render :show, status: :created, location: @post }
      else
        format.html { render :new }
        format.json { render json: @post.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /posts/1
  # PATCH/PUT /posts/1.json
  def update
    respond_to do |format|
      if @post.update(post_params)
        format.html { redirect_to @post, notice: 'Post was successfully updated.' }
        format.json { render :show, status: :ok, location: @post }
      else
        format.html { render :edit }
        format.json { render json: @post.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /posts/1
  # DELETE /posts/1.json
  def destroy
    @post.destroy
    respond_to do |format|
      format.html { redirect_to user_posts_path(current_user), notice: 'Post was successfully destroyed.' }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_post
      if current_user.admin?
        @post = Post.find(params[:id])
      else
        @post = current_user.posts.find_by(id: params[:id])
        @post = Post.where(id: params[:id]).where(public: true).first unless @post
      end
    end

    # Never trust parameters from the scary internet, only allow the white list through.
    def post_params
      params.require(:post).permit(:title, :content, :public)
    end
end