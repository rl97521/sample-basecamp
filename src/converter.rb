require 'podio'
require 'basecamp'
require 'yaml'

API_CONFIG = YAML::load(File.open('api_config.yml')) #Podio API config
api_config = API_CONFIG

Basecamp.establish_connection!(api_config['basecamp_url'], api_config['basecamp_username'], api_config['basecamp_password'], true)
@basecamp = Basecamp.new

Podio.setup(:api_key => api_config['api_key'], :api_secret => api_config['api_secret'], :debug => true)
Podio.client.authenticate_with_credentials(api_config['login'], api_config['password'])

def date_converter(date, s)
	if s == true
		date.to_s[5..-1].gsub!(/ /, '-')+ " 00:00:00"
	else
		date = date.to_s[0..-5]	
	end
	date	
end

def choose_podio_org
	puts 'This script will create one space/project.
Choose the Organization for these spaces now'
	Podio::Organization.find_all.each do |org|
	  puts "\t#{org['org_id']}: #{org['name']}"
	end
	puts "Org id: "
	org_id = gets.chomp
end



def create_user(user, space_id)
	Podio::Contact.create_space_contact(space_id, {
		:external_id => user['id'].to_s,
		:name => "#{user['first-name']} #{user['last-name']}",
		:mail => [user['email-address']]})
	
end

def create_users(project, space_id)
	bcusers = @basecamp.people(project.company.id, project.id).inject({}) {|users, user|
		users[user['email-address']] = user
		users
	}
	users = Podio::Contact.find_all_for_space(space_id, {:exclude_self => false,
			:contact_type => ""}).inject({}) { |users, user|
				unless user['mail'].nil?
					user['mail'].each do |mail|
						if bcusers.has_key?(mail)
							users[bcusers[mail]['id']] = user
							bcusers.delete(mail)
						end
					end
				end
			users
		}
	bcusers.each do |mail, user|
		users[user['id']] = create_user(user, space_id)
	end
	users
end

def import_milestones(project)
	@basecamp.milestones(project.id).inject({}) {|hash, m|
		items = Podio::Item.find_all_by_external_id(@apps['Milestones']['app_id'], m['id'])
		if items.count <= 0 #Check doesn't exist
			if @users.has_key?(m['responsible-party-id'].to_i)
				val = [{:value => @users[m['responsible-party-id']]['profile_id']}]
			else
				val = []
			end
	
			id = Podio::Item.create(@apps['Milestones']['app_id'], {:external_id=>m['id'].to_s, 'fields'=>[
				{:external_id=>'title', :values=>[{:value=>m['title']}]},
				{:external_id=>'whens-it-due', :values=>[{'start'=>date_converter(m['created-on'], false)}]},
				{:external_id=>'whos-responsible', :values=>val}]})
			comments = @basecamp.milestone_comments(m['id'])
			unless comments.nil?
				comments.each { |c|
				Podio::Comment.create('item', id.to_s, {:external_id => c[:id].to_s, :value =>"#{c[:body]}\n\nBy: #{@users[c[:author].to_i]['name']}"})}
			end			
			hash[m['id']] = {:item=>m, :podio_id=>id}
		else
			hash[m['id']] = {:item=>m, :podio_id=>items.all[0]['item_id']}
		end
		hash
	}
end

def create_or_update(app_id, external_item_id)
	if Podio::Item.find_all_by_external_id(app_id, external_item_id).count <= 0
		Podio::Item.create(app_id, external_item_id, yield)
	else
		Podio::Item.update(app_id, external_item_id, yield)
	end
end


def import_messages(project, milestones)
	Basecamp::Message.archive(project_id=project.id).each do |m|
		m = Basecamp::Message.find(m.id)

		if Podio::Item.find_all_by_external_id(@apps['Messages']['app_id'], m.id).count <= 0 #Check doesn't exist
			unless m.milestone_id == 0
				val = [{:value=>milestones[m.milestone_id][:podio_id]}]
			else
				val = []
			end
			if @users.has_key?(m.author_id)
				val2 = [{:value => @users[m.author_id]['profile_id']}]
			else
				val2 = []
			end
			
			id = Podio::Item.create(@apps['Messages']['app_id'], {:external_id=>m.id.to_s, 'fields'=>[
			{:external_id=>'title', :values=>[{:value=>m.title}]},
			{:external_id=>'body', :values=>[{:value=>m.body}]},
			{:external_id=>'originally-posted', :values=>[:start=>date_converter(m.posted_on, false)]},
			{:external_id=>'categories', :values=>[{:value=>Basecamp::Category.find(m.category_id).name}]},
			{:external_id=>'milestone', :values=>val},
			{:external_id=>'author', :values=>val2}
			]})

			unless m.comments.nil?
				m.comments.each do |c|
					Podio::Comment.create('item', id.to_s, {:external_id => c[:id].to_s,
					:value =>"#{c[:body]}\n\nBy: #{@users[c[:author].to_i]['name']}"})
				end
			end
		end
	end
end


org_id = choose_podio_org().to_i
def import_all(org_id)
	spaces = Podio::Space.find_all_for_org(org_id).inject({}) {|obj, x|
		obj[x['name']]=x
		obj
	}
	
	Basecamp::Project.find(:all).each {|project|
		if !spaces.has_key?(project.name)
			puts project.name+' not in Podio yet'
			spaces[project.name]= Podio::Space.create(
				{'org_id'=>org_id, 'name'=>project.name,
				 'post_on_new_app' => false, 'post_on_new_member' => false }
			)
			space = spaces[project.name]
			
		else
			puts "Already in Podio"
			puts project.name
			space = spaces[project.name]
		end
		@apps = Podio::Application.find_all_for_space(space['space_id']).inject({}) {
		|hash,app|
			if app['status'] == 'active'
				hash[app['config']['name']] = app
			end
			hash
		}
		unless @apps.has_key?('Messages')
			puts "Install these apps to the space first: https://podio.com/store/app/510-todo-list, https://podio.com/store/app/508-milestones, https://podio.com/store/app/509-messages"
		end
		@users = create_users(project, space['space_id'])
		
		milestones = import_milestones(project)
		import_messages(project, milestones)
		#import_tasks(project, milestones)
	}
end
import_all(org_id)