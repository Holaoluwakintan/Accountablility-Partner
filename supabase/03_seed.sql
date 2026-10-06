
insert into ap_categories (slug, family, label, sensitivity, faith, featured, sort) values
  ('reading','start','Reading','standard',false,true,1),
  ('prayer','start','Prayer','standard',true,true,2),
  ('studying','start','Studying','standard',false,true,3),
  ('bible_study','start','Bible study','standard',true,true,4),
  ('unwanted_habit','stop','An unwanted habit','personal',false,false,10),
  ('pornography','stop','Pornography','sensitive',false,false,11),
  ('masturbation','stop','Masturbation','sensitive',false,false,12),
  ('social_media','stop','Excessive social media','standard',false,false,13),
  ('gaming','stop','Gaming','standard',false,false,14),
  ('gambling','stop','Gambling','sensitive',false,false,15),
  ('substances','stop','Smoking or substances','sensitive',false,false,16),
  ('procrastination','stop','Procrastination','standard',false,false,17),
  ('exercise','start','Exercise','standard',false,false,20),
  ('journaling','start','Journaling','standard',false,false,24),
  ('creating','start','Creating','standard',false,false,25),
  ('healthy_routines','start','Healthy routines','standard',false,false,26),
  ('sleep','start','Sleep','standard',false,false,27),
  ('disciplined','become','More disciplined','standard',false,false,30),
  ('consistent','become','More consistent','standard',false,false,31),
  ('focused','become','More focused','standard',false,false,32),
  ('communicator','become','A better communicator','standard',false,false,33),
  ('professional','become','A better professional','standard',false,false,34),
  ('leader','become','A better leader','standard',false,false,35),
  ('relationships','become','Better relationships','personal',false,false,36),
  ('exam','achieve','Pass an exam','standard',false,false,40),
  ('finish_book','achieve','Finish a book','standard',false,false,41),
  ('build_project','achieve','Build a project','standard',false,false,42),
  ('launch_business','achieve','Launch a business','standard',false,false,43),
  ('find_job','achieve','Find a job','standard',false,false,44),
  ('save_money','achieve','Save money','personal',false,false,45),
  ('complete_course','achieve','Complete a course','standard',false,false,46),
  ('custom','other','Something else','standard',false,false,90)
on conflict (slug) do update set family = excluded.family, label = excluded.label, sensitivity = excluded.sensitivity,
  faith = excluded.faith, featured = excluded.featured, sort = excluded.sort;

delete from ap_crisis_resources;
insert into ap_crisis_resources (country_code, region, name, phone, url, hours, sort, verified_at) values
  ('NG', null, 'Emergency services (Nigeria)', '112', null, '24 hours, toll-free', 1, '2026-10-06'),
  ('NG', 'Lagos', 'Lagos State emergency line', '767', null, '24 hours, toll-free (or 112)', 2, '2026-10-06'),
  ('NG', null, 'Mentally Aware Nigeria Initiative (MANI)', '0809 111 6264', 'https://mentallyaware.org', 'Also 0811 168 0686', 3, '2026-10-06'),
  ('NG', null, 'SURPIN suicide prevention helpline', '0800 078 7746', 'https://www.surpinng.com', '24 hours, toll-free', 4, '2026-10-06'),
  (null, null, 'Find a free helpline in your country', null, 'https://findahelpline.com', '24 hours', 10, '2026-10-06');
